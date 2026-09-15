#!/usr/bin/env bash
# install.sh — make a bare `pi` in your terminal run on Claude Code (Ubuntu).
#
# Fixes "Warning: No models available. Use /login to log into a provider": pi ships with no
# provider configured, so it has nothing to talk to. This registers the claude-code provider
# extension in ~/.pi/agent/settings.json and points it at a local Claude Code bridge, so `pi`
# uses your Claude subscription — no pi /login, no API key.
#
#   1. checks python3 / node 20+ / jq / pi / claude (installs pi + jq if missing; claude must be logged in)
#   2. registers the pi-cli Claude Code bridge (:18187) as an enabled systemd --user service + linger
#   3. installs tools/pi-sessions + tools/pi-session-rm into ~/.local/bin
#   4. registers the provider extension in ~/.pi/agent/settings.json and makes
#      claude-code / claude-opus-5 pi's default provider + model (backup written first)
#   5. runs a headless smoke test (a pi bash call + a connector call)
#
#   ./install.sh | ./install.sh --no-default (steps 1-3 only; use ./run.sh pi) | ./install.sh --uninstall
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
MODEL="${PI_CLI_MODEL:-claude-opus-5}"
SETTINGS="$HOME/.pi/agent/settings.json"
EXT="$HERE/extensions/claude-code"
BIN_DIR="${PI_CLI_BIN_DIR:-$HOME/.local/bin}"

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = "Linux" ] || die "this is the Ubuntu/Linux tree — on macOS run ../../../macos/claude-code/pi-cli/install.sh"
[ "$(id -u)" -ne 0 ] || die "do not run as root — this is a per-user service and edits your own ~/.pi settings."

if [ "${1:-}" = "--uninstall" ]; then
  "$HERE/run.sh" uninstall-service
  for t in pi-sessions pi-session-rm; do
    [ -f "$BIN_DIR/$t" ] && cmp -s "$HERE/tools/$t" "$BIN_DIR/$t" && rm -f "$BIN_DIR/$t" && ok "removed $BIN_DIR/$t"
  done
  if [ -f "$SETTINGS" ] && have jq; then
    tmp="$(mktemp)"; jq --arg e "$EXT" '(.extensions // []) |= map(select(. != $e)) | if .defaultProvider == "claude-code" then del(.defaultProvider, .defaultModel) else . end | if .enabledModels then .enabledModels |= map(select(startswith("claude-code/") | not)) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "removed the extension and defaults from $SETTINGS"
  fi
  exit 0
fi
NO_DEFAULT=0; [ "${1:-}" = "--no-default" ] && NO_DEFAULT=1

have python3 || die "python3 not found — sudo apt-get install -y python3"
have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "Node.js 20+ required — see ../install.sh, which sets it up."
if ! have pi; then
  info "installing pi…"
  npm install -g @earendil-works/pi-coding-agent
  export PATH="$(npm prefix -g)/bin:$HOME/.local/bin:$PATH"
fi
have pi || die "'pi' not on PATH after install — add $(npm prefix -g)/bin to PATH and re-run."
ok "pi $(pi --version 2>&1 | head -1)"
have claude || die "Claude Code CLI not found — curl -fsSL https://claude.ai/install.sh | bash && claude login"
ok "Claude Code $(claude --version 2>&1 | head -1)"
probe="$(cd /tmp && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_AGENT_SDK_VERSION -u ANTHROPIC_BASE_URL \
          claude -p --tools "" --no-session-persistence --output-format json --model haiku 'Reply with exactly: pong' 2>&1 || true)"
printf '%s' "$probe" | grep -q '"result"' && ! printf '%s' "$probe" | grep -qi 'authenticate' || die "Claude Code login not working — run: claude login"
ok "Claude Code login works"

info "registering the pi-cli Claude Code bridge service (:${UPSTREAM_PORT:-18187})…"
"$HERE/run.sh" install-service

# pi has no non-interactive session list or delete of its own — these two fill that in.
# Skipped only if the user has their own copies (different content) already on PATH.
info "installing the session tools into $BIN_DIR…"
mkdir -p "$BIN_DIR"
for t in pi-sessions pi-session-rm; do
  if have "$t" && ! cmp -s "$HERE/tools/$t" "$(command -v "$t")"; then
    info "$t already on PATH at $(command -v "$t") and differs — leaving it alone"
  else
    install -m 755 "$HERE/tools/$t" "$BIN_DIR/$t"
  fi
done
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "pi-sessions / pi-session-rm installed in $BIN_DIR" ;;
  *) ok "pi-sessions / pi-session-rm installed in $BIN_DIR"
     info "note: $BIN_DIR is not on your PATH — add it in ~/.bashrc / ~/.zshrc: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ "$NO_DEFAULT" -eq 0 ]; then
  if ! have jq; then
    info "jq is required to edit $SETTINGS — installing…"
    have apt-get || die "apt-get not found; install jq manually or re-run with --no-default"
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
  fi
  have jq || die "jq still missing — install it or re-run with --no-default"
  mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  # enabledModels is pi's model SCOPE: when it exists, models outside it are ignored — including ours,
  # so a bare `pi` would silently fall back to whatever else is enabled. Put every claude-code model in
  # scope and drop the built-in anthropic entries (same ids, billed as third-party "extra usage").
  CC_MODELS="$(printf '%s' "${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}" | tr ',' '\n' | sed 's#^#claude-code/#' | jq -R . | jq -s .)"
  jq --arg e "$EXT" --arg m "$MODEL" --argjson cc "$CC_MODELS" '
      .extensions = ((.extensions // []) + [$e] | unique)
      | .defaultProvider = "claude-code" | .defaultModel = $m
      | if .enabledModels then .enabledModels = ((.enabledModels | map(select(startswith("anthropic/") | not))) + $cc | unique) else . end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ok "pi defaults set: provider claude-code, model $MODEL; claude-code/* models in scope (extension registered in $SETTINGS)"
fi

info "smoke test…"
"$HERE/run.sh" test
echo
ok "Done. In any directory just run:  pi"
echo "     /model  → switch between claude-opus-5, claude-fable-5-1, claude-sonnet-5 …"
echo "     ./run.sh service-status | logs | journal | restart | uninstall-service"
