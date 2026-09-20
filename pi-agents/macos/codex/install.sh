#!/usr/bin/env bash
# install.sh — make `pi` in your terminal able to run on the OpenAI Codex CLI.
#
#   1. checks python3 / node / pi / codex (installs pi if missing; codex must be installed + logged in)
#   2. registers the pure-LLM codex bridge (:18288) as an auto-start user service
#   3. registers the provider extension in ~/.pi/agent/settings.json and puts the
#      codex-cli/* models into pi's enabledModels scope (backup written first).
#      It does NOT steal pi's default provider — this backend is meant to sit next to
#      ../claude-code/pi-cli; pass --default if you want plain `pi` to start on it.
#   4. runs a headless smoke test (the model must call pi's bash tool itself)
#
#   ./install.sh | ./install.sh --default | ./install.sh --no-service | ./install.sh --uninstall
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
MODEL="${PI_CLI_MODEL:-gpt-5.6-sol}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18288}"
SETTINGS="$HOME/.pi/agent/settings.json"
EXT="$HERE/extensions/codex-cli"
SEED_MODELS="${PI_CODEX_CLI_MODELS:-$MODEL}"

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "${1:-}" = "--uninstall" ]; then
  "$HERE/run.sh" uninstall-service
  if [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"; jq --arg e "$EXT" '(.extensions // []) |= map(select(. != $e))
      | if .defaultProvider == "codex-cli" then del(.defaultProvider, .defaultModel) else . end
      | if .enabledModels then .enabledModels |= map(select(startswith("codex-cli/") | not)) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "removed the extension and its models from $SETTINGS"
  fi
  exit 0
fi
SET_DEFAULT=0; NO_SERVICE=0
case "${1:-}" in
  --default)    SET_DEFAULT=1 ;;
  --no-service) NO_SERVICE=1 ;;
  "") ;;
  *) die "unknown flag: $1 (use --default, --no-service or --uninstall)" ;;
esac

have python3 || die "python3 not found"
have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "Node.js 20+ required"
if ! have pi; then info "installing pi…"; npm install -g @earendil-works/pi-coding-agent; export PATH="$(npm prefix -g)/bin:$HOME/.local/bin:$PATH"; fi
have pi || die "'pi' not on PATH after install"
ok "pi $(pi --version 2>&1 | head -1)"

# Codex is NOT auto-installed: it needs an interactive `codex login` (ChatGPT plan or API key),
# which an installer cannot do for you.
have codex || die "'codex' not on PATH — install it (npm i -g @openai/codex) and run: codex login"
ok "codex $(codex --version 2>&1 | head -1)"
[ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ] \
  && ok "codex credentials present ($(basename "${CODEX_HOME:-$HOME/.codex}")/auth.json)" \
  || warn "no codex auth.json found — run: codex login   (the bridge will fail every turn until then)"

if [ "$NO_SERVICE" -eq 0 ]; then
  info "registering the pure-LLM codex bridge service (:${UPSTREAM_PORT})…"
  "$HERE/run.sh" install-service
else
  info "--no-service: start the bridge yourself with  ./run.sh upstream  (:${UPSTREAM_PORT})"
fi

have jq || die "jq is required to edit $SETTINGS (brew install jq)"
mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
# enabledModels is pi's model SCOPE: when it exists, models outside it are ignored — including ours,
# so `--provider codex-cli` would silently fall back to another enabled model.
LIVE="$(curl -fsS --max-time 10 "http://127.0.0.1:${UPSTREAM_PORT}/v1/models" 2>/dev/null \
        | python3 -c 'import sys,json; print(",".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null || true)"
[ -n "$LIVE" ] || { LIVE="$SEED_MODELS"; warn "bridge not answering yet — putting the seed model list in scope instead"; }
CX_MODELS="$(printf '%s' "$LIVE" | tr ',' '\n' | sed 's#^#codex-cli/#' | jq -R . | jq -s .)"
tmp="$(mktemp)"
jq --arg e "$EXT" --arg m "codex-cli/$MODEL" --argjson cx "$CX_MODELS" --argjson d "$SET_DEFAULT" '
    .extensions = ((.extensions // []) + [$e] | unique)
    | if .enabledModels then .enabledModels = (.enabledModels + $cx | unique) else . end
    | if $d == 1 then .defaultProvider = "codex-cli" | .defaultModel = ($m | sub("^codex-cli/"; "")) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
ok "extension registered in $SETTINGS; codex-cli/* models in scope$([ "$SET_DEFAULT" -eq 1 ] && echo "; default provider = codex-cli, model $MODEL")"

info "smoke test…"
"$HERE/run.sh" test || warn "smoke test failed — is the bridge up? ./run.sh service-status | logs"
echo
if [ "$SET_DEFAULT" -eq 1 ]; then
  ok "Done. In any directory just run:  pi"
else
  ok "Done. In any directory run:  pi --provider codex-cli --model $MODEL"
  echo "     (or ./run.sh pi — same thing; ./install.sh --default makes a bare \`pi\` use it)"
fi
echo "     ./run.sh logs | service-status | models | uninstall-service"
