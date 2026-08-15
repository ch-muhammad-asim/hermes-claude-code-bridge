#!/usr/bin/env bash
# Verify that the Codex tool patch is applied and actually working.
#
#   ./verify.sh                 run all checks against http://127.0.0.1:8080
#   NINEROUTER_URL=... ./verify.sh
#   NINEROUTER_API_KEY=... ./verify.sh
#
# Without a key it reads one from ../docker-compose/.env. Exits non-zero on the
# first failed assertion, so it is usable as a post-deploy gate.
#
# What it proves, in order:
#   1. the startup patch reported success in the container logs
#   2. the bundled chunk carries the patch marker
#   3. a Responses request with a `namespace` tool forwards BOTH children
#   4. the model can name the flattened tools (`exec`, `read_file`)
#   5. the model emits a real function_call to `exec` — the Desktop path
set -uo pipefail
cd "$(dirname "$0")"

URL="${NINEROUTER_URL:-http://127.0.0.1:8080}"
MODEL="${CODEX_TEST_MODEL:-oc/mimo-v2.5-free}"
COMPOSE_DIR="../docker-compose"

ok=$'\033[32m'; bad=$'\033[31m'; dim=$'\033[2m'; off=$'\033[0m'
fails=0
pass() { printf '  %s✓%s %s\n' "$ok" "$off" "$1"; }
fail() { printf '  %s✗%s %s\n' "$bad" "$off" "$1"; fails=$((fails+1)); }
info() { printf '%s── %s%s\n' "$dim" "$1" "$off"; }

# ── key ─────────────────────────────────────────────────────────────────────
# .env is the source of truth. An exported NINEROUTER_API_KEY (the Codex guide
# tells you to set one for the CLI) is often stale — using it blindly produced
# 401s that looked like patch failures. Prefer the export only if it works.
ENV_KEY=""
[ -f "$COMPOSE_DIR/.env" ] && ENV_KEY="$(sed -n 's/^NINEROUTER_API_KEY=//p' "$COMPOSE_DIR/.env" | tail -1)"
KEY="${NINEROUTER_API_KEY:-$ENV_KEY}"

http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$URL/v1/models" -H "Authorization: Bearer $1" 2>/dev/null; }

if [ -n "$KEY" ] && [ "$(http_code "$KEY")" != "200" ] && [ -n "$ENV_KEY" ] && [ "$KEY" != "$ENV_KEY" ]; then
  printf '%s⚠ exported NINEROUTER_API_KEY is stale — using the one from .env%s\n' "$dim" "$off"
  KEY="$ENV_KEY"
fi
if [ -z "$KEY" ]; then
  echo "${bad}no API key — run ../docker-compose/generate.sh --key-only${off}" >&2
  exit 2
fi
if [ "$(http_code "$KEY")" != "200" ]; then
  echo "${bad}API key does not authenticate — run ../docker-compose/generate.sh --key-only${off}" >&2
  exit 2
fi

info "patch applied at startup"
# Captured to a variable, not piped: `grep -q` exits on first match, SIGPIPEs
# `docker compose logs`, and `set -o pipefail` would then report the whole
# pipeline as failed even though the match succeeded.
LOGS="$( (cd "$COMPOSE_DIR" && docker compose logs 9router) 2>/dev/null || true )"
case "$LOGS" in
  *"namespace flattening applied"*) pass "container logged: namespace flattening applied" ;;
  *"already applied"*)              pass "container logged: patch already applied" ;;
  *"WARNING: pattern not found"*)   fail "patch script ran but the pattern is gone — 9Router build changed" ;;
  *)                                fail "no [codex-patch] line in 9router logs — is the entrypoint wrapper wired up?" ;;
esac

info "patch marker present in the bundled chunk"
MARKER="$( (cd "$COMPOSE_DIR" && docker compose exec -T 9router sh -lc \
      'grep -l __CODEX_NS_FLATTEN__ /app/.next/server/chunks/*.js 2>/dev/null | head -1') 2>/dev/null || true )"
case "$MARKER" in
  *chunks*) pass "marker found in ${MARKER##*/}" ;;
  *)        fail "marker missing — the running code is NOT patched" ;;
esac

# ── live request with a two-child namespace ─────────────────────────────────
req() {  # req <user-text>
  cat <<EOF
{"model":"$MODEL","stream":false,
 "input":[{"role":"user","content":[{"type":"input_text","text":"$1"}]}],
 "tools":[{"type":"namespace","name":"functions","tools":[
   {"type":"function","name":"exec","description":"Run a shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}},
   {"type":"function","name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
 ]},{"type":"local_shell"}]}
EOF
}

post() { curl -sS --max-time 240 "$URL/v1/responses" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' -d "$1"; }

info "both namespace children forwarded upstream"
LOG_LINES_BEFORE="$( (cd "$COMPOSE_DIR" && docker compose logs 9router) 2>/dev/null | wc -l | tr -d ' ' )"
post "$(req 'Do not call anything. List the exact names of every tool you can call, one per line.')" > /tmp/codex-verify-names.json 2>&1
LOGS_AFTER="$( (cd "$COMPOSE_DIR" && docker compose logs 9router) 2>/dev/null | tail -n +$((LOG_LINES_BEFORE+1)) )"
NAMES="$(python3 -c "
import json
try: d=json.load(open('/tmp/codex-verify-names.json'))
except Exception: print(''); raise SystemExit
print(' '.join(c.get('text','') for o in d.get('output',[]) if o.get('type')=='message' for c in o.get('content',[])))
" 2>/dev/null)"
if printf '%s' "$NAMES" | grep -q exec && printf '%s' "$NAMES" | grep -q read_file; then
  pass "model lists both: exec, read_file"
else
  fail "model did not list both children — got: $(printf '%s' "$NAMES" | head -c 120)"
fi

# Count only the lines our own request produced: snapshot the log length first,
# then read the tail. `--since` caught unrelated traffic (e.g. a catalog warm
# sending 18 tools) and reported a bogus number.
TOOLCOUNT="$(printf '%s' "$LOGS_AFTER" | grep '▶ POST' | tail -1 | grep -oE '[0-9]+ TOOLS?' | grep -oE '[0-9]+')"
if [ "${TOOLCOUNT:-0}" -ge 2 ]; then
  pass "9Router forwarded $TOOLCOUNT tools (unpatched sends 1)"
else
  fail "9Router forwarded ${TOOLCOUNT:-?} tool(s) — namespace was not flattened"
fi

info "model emits a real function_call to exec"
post "$(req 'List the contents of the current directory. You must call the exec tool to do it.')" > /tmp/codex-verify-call.json 2>&1
CALL="$(python3 -c "
import json
try: d=json.load(open('/tmp/codex-verify-call.json'))
except Exception: print(''); raise SystemExit
print(next((o.get('name','') for o in d.get('output',[]) if o.get('type')=='function_call'), ''))
" 2>/dev/null)"
case "$CALL" in
  exec)      pass "function_call -> exec" ;;
  functions) fail "function_call -> 'functions' (the namespace container) — patch not effective" ;;
  "")        fail "no function_call emitted — model refused or upstream errored" ;;
  *)         fail "unexpected function_call -> '$CALL'" ;;
esac

rm -f /tmp/codex-verify-names.json /tmp/codex-verify-call.json
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '%sCodex tool patch verified%s\n' "$ok" "$off"
else
  printf '%s%d check(s) failed — see ./TROUBLESHOOTING.md%s\n' "$bad" "$fails" "$off"
fi
exit $(( fails > 0 ? 1 : 0 ))
