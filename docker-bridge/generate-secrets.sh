#!/usr/bin/env bash
# Generate the bearer token this bridge requires, and optionally relax its defaults.
#
#   ./generate-secrets.sh                    # fill secrets into ./.env (creates it from env.example)
#   ./generate-secrets.sh --print            # just print the generated lines, change nothing
#   ./generate-secrets.sh --force            # regenerate values that are already set
#   ./generate-secrets.sh --all-tools        # clear the tool deny list (Bash/Edit/Write become usable)
#   ./generate-secrets.sh --allow-anonymous  # serve WITHOUT a bearer token
#   ./generate-secrets.sh --require-api-key  # REQUIRE a bearer token (leaves tools untouched)
#   ./generate-secrets.sh --secure           # restore both defaults (deny list on, token required)
#   ./generate-secrets.sh --show-secrets     # also print secret VALUES to the shell
#   ./generate-secrets.sh --setup-token      # mint a LONG-LIVED Claude token and store it
#   ./generate-secrets.sh --oauth-token TOK  # store a token you already have
#   ./generate-secrets.sh --no-host-token    # do NOT auto-adopt the host login
#
# By default, on a host whose Claude Code login is active but unreachable from a
# container (macOS keychain / Windows credential manager), the active token is
# adopted automatically so `docker compose up -d` just works.
#   ./generate-secrets.sh -f PATH            # operate on a different env file
#
# --setup-token is the recommended one-time setup on macOS/Windows: it makes
# `docker compose up -d` self-sufficient, with no keychain access and nothing to
# lose when the claude-home volume is recreated.
#
# --all-tools and --allow-anonymous each remove a safety default; both print what
# they grant. --require-api-key re-enables auth on its own; --secure does that AND
# restores the tool deny list.
#
# It edits in place rather than appending. Appending leaves TWO entries per key
# (the empty placeholder from env.example plus the real one): docker compose reads
# the last occurrence so the stack still works, but `grep -m1 KEY .env` then returns
# the empty one — a confusing footgun that is easy to debug for far too long.
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
MODE="fill"
FORCE=0
ALL_TOOLS=0
ALLOW_ANON=0
REQUIRE_KEY=0
SECURE=0
SHOW_SECRETS=0
SETUP_TOKEN=0
OAUTH_TOKEN=""
NO_HOST_TOKEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print)                    MODE="print"; shift ;;
    --force)                    FORCE=1; shift ;;
    --all-tools)                ALL_TOOLS=1; shift ;;
    --allow-anonymous)          ALLOW_ANON=1; shift ;;
    --require-api-key|--api-key) REQUIRE_KEY=1; shift ;;
    --secure)                   SECURE=1; shift ;;
    --show-secrets)             SHOW_SECRETS=1; shift ;;
    --setup-token)              SETUP_TOKEN=1; shift ;;
    --no-host-token)            NO_HOST_TOKEN=1; shift ;;
    --oauth-token)              OAUTH_TOKEN="${2:?--oauth-token needs a value}"; shift 2 ;;
    -f|--file)                  ENV_FILE="${2:?--file needs a path}"; shift 2 ;;
    -h|--help)                  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 64 ;;
  esac
done

if [ "$SECURE" -eq 1 ] && { [ "$ALL_TOOLS" -eq 1 ] || [ "$ALLOW_ANON" -eq 1 ]; }; then
  echo "--secure cannot be combined with --all-tools/--allow-anonymous" >&2
  exit 64
fi
if [ "$REQUIRE_KEY" -eq 1 ] && [ "$ALLOW_ANON" -eq 1 ]; then
  echo "--require-api-key and --allow-anonymous are opposites; pick one" >&2
  exit 64
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

KEYS="CLAUDE_CODE_PROXY_API_KEY"

if [ "$MODE" = "print" ]; then
  for k in $KEYS; do printf '%s=%s\n' "$k" "$(openssl rand -hex 32)"; done
  exit 0
fi

if [ ! -f "$ENV_FILE" ]; then
  [ -f env.example ] || { echo "no $ENV_FILE and no env.example to copy" >&2; exit 1; }
  cp env.example "$ENV_FILE"
  echo "created $ENV_FILE from env.example"
fi

# Set KEY=VALUE in place: rewrite the first occurrence, drop later duplicates so a
# stale line can never shadow the real value. Appends if the key is absent.
set_key() {
  local key="$1" val="$2" tmp
  if grep -q "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$val" '
      $0 ~ "^" key "=" { if (!seen) { print key "=" val; seen = 1 } ; next }
      { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# An empty key while PROXY_ALLOW_ANONYMOUS=true is a DELIBERATE state, not a missing
# secret. Filling it in would silently re-enable auth — and because a non-empty key
# always wins over the flag in docker-entrypoint.sh, the file would then contradict
# itself and clients would start getting 401s again.
anon_configured=0
[ "$(sed -n 's/^PROXY_ALLOW_ANONYMOUS=//p' "$ENV_FILE" | tail -1)" = "true" ] && anon_configured=1

for k in $KEYS; do
  current="$(sed -n "s/^${k}=//p" "$ENV_FILE" | tail -1)"
  if [ -n "$current" ] && [ "$FORCE" -eq 0 ] && [ "$ALLOW_ANON" -eq 0 ]; then
    echo "  $k already set — leaving it (use --force to regenerate)"
    continue
  fi
  if [ "$ALLOW_ANON" -eq 1 ]; then
    set_key "$k" ""
    continue
  fi
  if [ -z "$current" ] && [ "$anon_configured" -eq 1 ] \
     && [ "$FORCE" -eq 0 ] && [ "$SECURE" -eq 0 ] && [ "$REQUIRE_KEY" -eq 0 ]; then
    echo "  $k left empty — PROXY_ALLOW_ANONYMOUS=true"
    echo "    (use --require-api-key to turn auth back on, or --secure to reset everything)"
    continue
  fi
  set_key "$k" "$(openssl rand -hex 32)"
  echo "  $k set"
done

if [ "$ALL_TOOLS" -eq 1 ]; then
  # An EMPTY allow list means "no explicit allowlist", not "everything": the deny
  # list still wins. Enabling every tool therefore means clearing the DENY list.
  set_key CLAUDE_CODE_DISALLOWED_TOOLS ""
  set_key CLAUDE_CODE_ALLOWED_TOOLS ""
  cat <<'EOF'

  ALL TOOLS ENABLED — the deny list is now empty.
    Bash, Edit, Write and NotebookEdit become available to any client of this
    bridge. The agent can execute commands and modify files inside the container
    (workspace volume + its own $HOME). Keep PROXY_BIND on 127.0.0.1.
EOF
fi

if [ "$ALLOW_ANON" -eq 1 ]; then
  set_key PROXY_ALLOW_ANONYMOUS "true"
  cat <<'EOF'

  ANONYMOUS ACCESS ENABLED — no bearer token required.
    Any process on this host that can reach the port drives your Claude Code
    session and spends against your account. Keep PROXY_BIND on 127.0.0.1.
EOF
fi

if [ "$REQUIRE_KEY" -eq 1 ]; then
  # Auth back on WITHOUT touching the tool lists — the narrow counterpart to --secure.
  set_key PROXY_ALLOW_ANONYMOUS "false"
  current="$(sed -n "s/^CLAUDE_CODE_PROXY_API_KEY=//p" "$ENV_FILE" | tail -1)"
  [ -n "$current" ] || set_key CLAUDE_CODE_PROXY_API_KEY "$(openssl rand -hex 32)"
  echo "  API KEY REQUIRED — clients must send: Authorization: Bearer <key>"
  echo "    Tool settings left as they are."
fi

# The container runs as the host uid so it can read AND refresh the bind-mounted
# ~/.claude. A mismatch here is the difference between "works" and a CLI that
# cannot write its own refreshed token.
if command -v id >/dev/null 2>&1; then
  set_key HOST_UID "$(id -u)"
  set_key HOST_GID "$(id -g)"
fi

# macOS keeps the live token in the keychain and leaves ~/.claude/.credentials.json
# as a stale copy. The container reads the FILE, so refresh it from the keychain —
# same session, no re-login. This is also what makes the claude.ai connectors
# (Slack, Drive, Atlassian…) visible inside the container: they are attached to the
# account session and require a full credentials file. An env CLAUDE_CODE_OAUTH_TOKEN
# authenticates completions but surfaces NO connectors.
host_dir="$(sed -n 's/^HOST_CLAUDE_DIR=//p' "$ENV_FILE" | tail -1)"
[ -n "$host_dir" ] || host_dir="$HOME/.claude"
if [ "$NO_HOST_TOKEN" -eq 0 ] && command -v security >/dev/null 2>&1; then
  # `|| true`: a host with no "Claude Code-credentials" keychain item makes
  # `security` exit 44, and under set -e an unguarded substitution assignment
  # kills the whole script silently. Empty $fresh is handled just below.
  fresh="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
  if printf '%s' "$fresh" | python3 -c '
import sys, json, time
try:
    t = json.load(sys.stdin)["claudeAiOauth"]
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if t["expiresAt"] / 1000 - time.time() > 0 else 1)
' 2>/dev/null; then
    mkdir -p "$host_dir"
    ( umask 077; printf '%s' "$fresh" > "$host_dir/.credentials.json" )
    hours="$(printf '%s' "$fresh" | python3 -c 'import sys,json,time;t=json.load(sys.stdin)["claudeAiOauth"];print("%.1f"%((t["expiresAt"]/1000-time.time())/3600))')"
    echo "  refreshed $host_dir/.credentials.json from the keychain (valid ~${hours}h)"
    echo "    the container bind-mounts this directory, so it now shares your host"
    echo "    session; the CLI refreshes the credential in place"
  fi
fi

if [ "$SETUP_TOKEN" -eq 1 ]; then
  command -v claude >/dev/null 2>&1 || {
    echo "claude CLI not found on PATH — install it or use --oauth-token" >&2; exit 1; }
  echo "  running: claude setup-token   (a browser window may open)"
  # Tee so the user still sees the CLI's own prompts while we capture the token.
  token_out="$(claude setup-token 2>&1 | tee /dev/tty)" || {
    echo "claude setup-token failed" >&2; exit 1; }
  OAUTH_TOKEN="$(printf '%s' "$token_out" | grep -oE 'sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]+' | tail -1)"
  [ -n "$OAUTH_TOKEN" ] || {
    echo "could not find an sk-ant-oat… token in the output; re-run with --oauth-token <token>" >&2
    exit 1; }
fi

if [ -n "$OAUTH_TOKEN" ]; then
  set_key CLAUDE_CODE_OAUTH_TOKEN "$OAUTH_TOKEN"
  echo "  CLAUDE_CODE_OAUTH_TOKEN stored — \`docker compose up -d\` is now self-sufficient"
  echo "    (no keychain access, and recreating the claude-home volume cannot break auth)"
fi

if [ "$SECURE" -eq 1 ]; then
  set_key CLAUDE_CODE_DISALLOWED_TOOLS "Bash,Edit,Write,NotebookEdit"
  set_key PROXY_ALLOW_ANONYMOUS "false"
  current="$(sed -n "s/^CLAUDE_CODE_PROXY_API_KEY=//p" "$ENV_FILE" | tail -1)"
  [ -n "$current" ] || set_key CLAUDE_CODE_PROXY_API_KEY "$(openssl rand -hex 32)"
  echo "  restored defaults: tool deny list on, bearer token required"
fi

api_key="$(sed -n 's/^CLAUDE_CODE_PROXY_API_KEY=//p' "$ENV_FILE" | tail -1)"
oauth_token="$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$ENV_FILE" | tail -1)"

# Classify the Claude credential HONESTLY. The prefix is not a signal: a keychain
# ACCESS token and a `claude setup-token` credential both start sk-ant-oat01-, but
# the former expires in hours. Compare against the live keychain value instead —
# if they match, this token inherits that short lifetime and will die mid-session.
claude_auth="bind-mounted host credentials"
if [ -n "$oauth_token" ]; then
  claude_auth="CLAUDE_CODE_OAUTH_TOKEN set - NO claude.ai connectors"
  if command -v security >/dev/null 2>&1; then
    kc="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)"
    if [ -n "$kc" ] && [ "$kc" = "$oauth_token" ]; then
      claude_auth="SHORT-LIVED keychain token - expires in hours, NO connectors"
    fi
  fi
fi

cat <<EOF

Written to $ENV_FILE (gitignored). Apply it:

  docker compose up -d --build

Effective settings:
  CLAUDE_CODE_PROXY_MODEL=$(sed -n 's/^CLAUDE_CODE_PROXY_MODEL=//p' "$ENV_FILE" | tail -1)
  CLAUDE_CODE_DISALLOWED_TOOLS=$(sed -n 's/^CLAUDE_CODE_DISALLOWED_TOOLS=//p' "$ENV_FILE" | tail -1)
  CLAUDE_CODE_ALLOWED_TOOLS=$(sed -n 's/^CLAUDE_CODE_ALLOWED_TOOLS=//p' "$ENV_FILE" | tail -1)
  CLAUDE_CODE_PERMISSION_MODE=$(sed -n 's/^CLAUDE_CODE_PERMISSION_MODE=//p' "$ENV_FILE" | tail -1)
  PROXY_ALLOW_ANONYMOUS=$(sed -n 's/^PROXY_ALLOW_ANONYMOUS=//p' "$ENV_FILE" | tail -1)
  PROXY_BIND=$(sed -n 's/^PROXY_BIND=//p' "$ENV_FILE" | tail -1)
  PROXY_PORT=$(sed -n 's/^PROXY_PORT=//p' "$ENV_FILE" | tail -1)
  all tools available=$([ -z "$(sed -n 's/^CLAUDE_CODE_DISALLOWED_TOOLS=//p' "$ENV_FILE" | tail -1)" ] && echo yes || echo no)
  api key required=$([ -n "$api_key" ] && echo yes || echo no)
  claude auth=$claude_auth
EOF

case "$claude_auth" in
  SHORT-LIVED*)
    cat <<'EOF'

  WARNING: CLAUDE_CODE_OAUTH_TOKEN is a copy of the macOS keychain ACCESS token.
    It shares the sk-ant-oat01- prefix with a long-lived token but expires within
    hours, so the bridge will start returning "Not logged in" mid-session.
    For something durable:  ./generate-secrets.sh --setup-token
EOF
    ;;
esac

if [ -n "$api_key" ]; then
  if [ "$SHOW_SECRETS" -eq 1 ]; then
    cat <<EOF

SECRETS — save these now:
  CLAUDE_CODE_PROXY_API_KEY=$api_key

Use it:
  curl -sS http://127.0.0.1:$(sed -n 's/^PROXY_PORT=//p' "$ENV_FILE" | tail -1)/v1/models \\
    -H "Authorization: Bearer $api_key"
EOF
  else
    cat <<EOF

Secret values hidden. Print them with --show-secrets, or read them directly:
  grep -m1 '^CLAUDE_CODE_PROXY_API_KEY=' $ENV_FILE
EOF
  fi
fi
