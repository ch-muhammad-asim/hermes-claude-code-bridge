#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the pi-agents OpenCode backend on Ubuntu.
#   ./install.sh | ./install.sh --no-service | ./install.sh --uninstall
# Installs Python/Node 20+/pi/OpenCode if missing, runs the self-checks and registers both
# bridges (:18385 pure-LLM OpenCode, :18484 pi) as enabled systemd --user services with
# linger on, so they come back after a reboot. Idempotent.
set -euo pipefail
BACKEND_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$BACKEND_DIR/.env" ] && { set -a; . "$BACKEND_DIR/.env"; set +a; }
BACKEND_NAME="opencode"
BRIDGE_PORT="${BRIDGE_PORT:-18484}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18385}"
MODEL="${PI_BRIDGE_MODEL:-opencode/mimo-v2.5-free}"

backend_install_deps() {
  if ! have opencode; then
    have curl || die "curl not found — sudo apt-get install -y curl, then re-run."
    info "OpenCode not found — installing via the official script..."
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
  fi
  have opencode || die "'opencode' still not on PATH — open a new shell (or add ~/.opencode/bin to PATH) and re-run."
  ok "OpenCode $(opencode --version 2>&1 | head -1)"
  local n; n="$(opencode models opencode 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then ok "$n OpenCode free models visible"; else
    warn "opencode models opencode listed nothing — the pure-LLM bridge will fall back to its seed list; check your network."; fi
}

. "$BACKEND_DIR/../common/install-lib.sh"
