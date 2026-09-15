#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the pi-agents Claude Code backend on Ubuntu.
#   ./install.sh | ./install.sh --no-service | ./install.sh --uninstall
# Installs Python/Node 20+/pi/Claude Code if missing, checks the Claude login, runs the
# self-checks and registers both bridges (:18186 native Claude Code, :18485 pi) as enabled
# systemd --user services with linger on, so they come back after a reboot.
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
    have curl || die "curl not found — sudo apt-get install -y curl, then re-run."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
  fi
  have claude || die "'claude' still not on PATH — open a new shell (or add ~/.local/bin to PATH) and re-run."
  ok "Claude Code $(claude --version 2>&1 | head -1)"
  # A cheap, tool-less probe: proves the login works and that --tools "" is honoured.
  # Run it with the Claude Code session variables cleared, exactly as the service will.
  local probe
  probe="$(cd /tmp && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_AGENT_SDK_VERSION -u ANTHROPIC_BASE_URL \
            claude -p --tools "" --no-session-persistence --output-format json --model haiku 'Reply with exactly: pong' 2>&1 || true)"
  if printf '%s' "$probe" | grep -q '"result"' && ! printf '%s' "$probe" | grep -qi 'authenticate\|login'; then
    ok "Claude Code login works (tool-less probe answered)"
  else
    warn "Claude Code could not answer a probe — usually the login expired."
    echo "     Run:  claude login      (then re-run ./install.sh)"
    echo "     Detail: $(printf '%s' "$probe" | head -c 200)"
    die "authenticate Claude Code first"
  fi
  # The service starts at boot with no desktop session: the credentials must be on disk, not in
  # a keyring that unlocks at login.
  if [ ! -s "$HOME/.claude/.credentials.json" ]; then
    warn "no ~/.claude/.credentials.json — if Claude Code kept your token in the GNOME keyring,"
    echo "     the boot-time service cannot read it until you unlock the session. Check after a reboot:"
    echo "       systemctl --user status ${BACKEND_NAME:+pi-upstream-claude-code}.service"
  fi
}

. "$BACKEND_DIR/../common/install-lib.sh"
