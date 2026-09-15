#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the pi-agents Claude Code backend (make it persistent).
#   ./install.sh | ./install.sh --no-service | ./install.sh --uninstall
# Installs Python/Node/pi/Claude Code if missing, checks the Claude login, runs the self-checks
# and registers both bridges (:18186 pure-LLM Claude Code, :18485 pi) as auto-start user services.
set -euo pipefail
BACKEND_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$BACKEND_DIR/.env" ] && { set -a; . "$BACKEND_DIR/.env"; set +a; }
BACKEND_NAME="claude-code"
BRIDGE_PORT="${BRIDGE_PORT:-18485}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18186}"
MODEL="${PI_BRIDGE_MODEL:-claude-opus-5}"

backend_install_deps() {
  if ! have claude; then
    info "Claude Code not found — installing (native installer)..."
    have curl || die "curl not found — install Claude Code manually: https://claude.com/claude-code"
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
  fi
  have claude || die "'claude' still not on PATH — open a new shell (or add ~/.local/bin to PATH) and re-run."
  ok "Claude Code $(claude --version 2>&1 | head -1)"
  # A cheap, tool-less probe: proves the login works and that --tools "" is honoured.
  local probe
  probe="$(cd /tmp && claude -p --tools "" --no-session-persistence --output-format json --model haiku 'Reply with exactly: pong' 2>&1 || true)"
  if printf '%s' "$probe" | grep -q '"result"' && ! printf '%s' "$probe" | grep -qi 'authenticate\|login'; then
    ok "Claude Code login works (tool-less probe answered)"
  else
    warn "Claude Code could not answer a probe — usually the login expired."
    echo "     Run:  claude login      (then re-run ./install.sh)"
    echo "     Detail: $(printf '%s' "$probe" | head -c 200)"
    die "authenticate Claude Code first"
  fi
}

. "$BACKEND_DIR/../common/install-lib.sh"
