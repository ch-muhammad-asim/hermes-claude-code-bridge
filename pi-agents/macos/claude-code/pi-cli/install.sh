#!/usr/bin/env bash
# install.sh — make `pi` in your terminal run on Claude Code, with every claude.ai connector, no guardrails.
#
#   1. checks python3 / node / pi / claude (installs pi if missing; claude must already be logged in)
#   2. registers the pi-cli Claude Code bridge (:18187) as an auto-start user service
#   3. installs tools/pi-sessions + tools/pi-session-rm into ~/.local/bin
#   4. registers the provider extension in ~/.pi/agent/settings.json and makes
#      claude-code / claude-opus-5 pi's default provider + model (backup written first)
#   5. runs a headless smoke test (a pi bash call + a connector call)
#
#   ./install.sh | ./install.sh --no-default (steps 1-2 + 4 only; use ./run.sh pi) | ./install.sh --uninstall
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
MODEL="${PI_CLI_MODEL:-claude-opus-5}"
SETTINGS="$HOME/.pi/agent/settings.json"
EXT="$HERE/extensions/claude-code"
BIN_DIR="${PI_CLI_BIN_DIR:-$HOME/.local/bin}"

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

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

have python3 || die "python3 not found"
have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "Node.js 20+ required"
if ! have pi; then info "installing pi…"; npm install -g @earendil-works/pi-coding-agent; export PATH="$(npm prefix -g)/bin:$HOME/.local/bin:$PATH"; fi
have pi || die "'pi' not on PATH after install"
ok "pi $(pi --version 2>&1 | head -1)"
have claude || die "Claude Code CLI not found — install it and log in first"
ok "Claude Code $(claude --version 2>&1 | head -1)"
probe="$(cd /tmp && claude -p --tools "" --no-session-persistence --output-format json --model haiku 'Reply with exactly: pong' 2>&1 || true)"
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
     info "note: $BIN_DIR is not on your PATH — add it in ~/.zshrc: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ "$NO_DEFAULT" -eq 0 ]; then
  have jq || die "jq is required to edit $SETTINGS (brew install jq), or re-run with --no-default"
  mkdir -p "$(dirname "$SETTINGS")"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  # enabledModels is pi's model SCOPE: when it exists, models outside it are ignored — including ours,
  # so a bare `pi` would silently fall back to whatever else is enabled. Put every claude-code model in
  # scope and drop the built-in anthropic entries (same ids, billed as third-party "extra usage").
  CC_MODELS="$(printf '%s' "${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-opus-5-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}" | tr ',' '\n' | sed 's#^#claude-code/#' | jq -R . | jq -s .)"
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
echo "     ./run.sh logs | service-status | uninstall-service"
