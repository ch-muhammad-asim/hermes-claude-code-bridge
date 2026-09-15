#!/usr/bin/env bash
# install.sh — make `pi` in your terminal able to run on OpenCode's FREE models.
#
#   1. checks python3 / node / pi / opencode (installs pi and OpenCode if missing)
#   2. registers the pure-LLM OpenCode bridge (:18386) as an auto-start user service
#   3. registers the provider extension in ~/.pi/agent/settings.json and puts the
#      opencode-cli/* models into pi's enabledModels scope (backup written first).
#      It does NOT steal pi's default provider — this backend is meant to sit next to
#      ../claude-code/pi-cli; pass --default if you want plain `pi` to start on it.
#   4. runs a headless smoke test (the free model must call pi's bash tool itself)
#
#   ./install.sh | ./install.sh --default | ./install.sh --no-service | ./install.sh --uninstall
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
MODEL="${PI_CLI_MODEL:-opencode/mimo-v2.5-free}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18386}"
SETTINGS="$HOME/.pi/agent/settings.json"
EXT="$HERE/extensions/opencode-cli"
SEED_MODELS="${PI_OPENCODE_CLI_MODELS:-opencode/mimo-v2.5-free,opencode/big-pickle,opencode/nemotron-3-ultra-free}"

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "${1:-}" = "--uninstall" ]; then
  "$HERE/run.sh" uninstall-service
  if [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"; jq --arg e "$EXT" '(.extensions // []) |= map(select(. != $e))
      | if .defaultProvider == "opencode-cli" then del(.defaultProvider, .defaultModel) else . end
      | if .enabledModels then .enabledModels |= map(select(startswith("opencode-cli/") | not)) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
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

if ! have opencode; then
  if have brew; then info "OpenCode not found — installing via Homebrew…"; brew install sst/tap/opencode || brew install opencode
  else
    have curl || die "curl not found — install OpenCode manually from https://opencode.ai"
    info "OpenCode not found — installing via the official script…"; curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
  fi
fi
have opencode || die "'opencode' still not on PATH — open a new shell (or add ~/.opencode/bin to PATH) and re-run."
ok "OpenCode $(opencode --version 2>&1 | head -1)"
n="$(opencode models opencode 2>/dev/null | grep -c . || true)"
[ "${n:-0}" -gt 0 ] && ok "$n OpenCode free models visible" \
  || warn "opencode models opencode listed nothing — the bridge falls back to its seed list; check your network / OpenCode login."

if [ "$NO_SERVICE" -eq 0 ]; then
  info "registering the pure-LLM OpenCode bridge service (:${UPSTREAM_PORT})…"
  "$HERE/run.sh" install-service
else
  info "--no-service: start the bridge yourself with  ./run.sh upstream  (:${UPSTREAM_PORT})"
fi

have jq || die "jq is required to edit $SETTINGS (brew install jq)"
mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
# enabledModels is pi's model SCOPE: when it exists, models outside it are ignored — including ours,
# so `--provider opencode-cli` would silently fall back to another enabled model. Ask the running
# bridge which free models it has (that list changes over time) and put them all in scope.
LIVE="$(curl -fsS --max-time 10 "http://127.0.0.1:${UPSTREAM_PORT}/v1/models" 2>/dev/null \
        | python3 -c 'import sys,json; print(",".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null || true)"
[ -n "$LIVE" ] || { LIVE="$SEED_MODELS"; warn "bridge not answering yet — putting the seed model list in scope instead"; }
OC_MODELS="$(printf '%s' "$LIVE" | tr ',' '\n' | sed 's#^#opencode-cli/#' | jq -R . | jq -s .)"
tmp="$(mktemp)"
jq --arg e "$EXT" --arg m "opencode-cli/$MODEL" --argjson oc "$OC_MODELS" --argjson d "$SET_DEFAULT" '
    .extensions = ((.extensions // []) + [$e] | unique)
    | if .enabledModels then .enabledModels = (.enabledModels + $oc | unique) else . end
    | if $d == 1 then .defaultProvider = "opencode-cli" | .defaultModel = ($m | sub("^opencode-cli/"; "")) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
ok "extension registered in $SETTINGS; opencode-cli/* models in scope$([ "$SET_DEFAULT" -eq 1 ] && echo "; default provider = opencode-cli, model $MODEL")"

info "smoke test…"
"$HERE/run.sh" test || warn "smoke test failed — is the bridge up? ./run.sh service-status | logs"
echo
if [ "$SET_DEFAULT" -eq 1 ]; then
  ok "Done. In any directory just run:  pi"
else
  ok "Done. In any directory run:  pi --provider opencode-cli --model $MODEL"
  echo "     (or ./run.sh pi — same thing; ./install.sh --default makes a bare \`pi\` use it)"
fi
echo "     /model  → switch between the opencode/* free models"
echo "     ./run.sh logs | service-status | models | uninstall-service"
