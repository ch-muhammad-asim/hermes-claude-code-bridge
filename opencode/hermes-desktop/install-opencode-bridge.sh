#!/usr/bin/env bash
# install-opencode-bridge.sh - one-shot macOS/Linux bootstrap for the OpenCode Bridge.
#
# Installs everything a fresh machine needs to expose an OpenAI-compatible endpoint
# backed by your authenticated OpenCode CLI (free opencode zen models):
#
#   1. Python 3      (the bridge is stdlib-only)
#   2. OpenCode CLI  (Homebrew, or the official install script)
#   3. The bridge    (launchd LaunchAgent / systemd --user unit, auto-starts at login)
#
# Idempotent - safe to re-run. Nothing here needs sudo: the service runs as YOU, so it
# inherits your interactive `opencode` credentials (~/.local/share/opencode/auth.json).
#
# Usage (from this folder):
#   ./install-opencode-bridge.sh              # full install + start the service
#   ./install-opencode-bridge.sh --no-service # install deps only, don't register the service
#
# Endpoint after install: http://127.0.0.1:18282/v1  (model: opencode/mimo-v2.5-free)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NO_SERVICE=0
[ "${1:-}" = "--no-service" ] && NO_SERVICE=1

BRIDGE_PORT="${BRIDGE_PORT:-18282}"
MODEL="${OPENCODE_BRIDGE_MODEL:-opencode/mimo-v2.5-free}"

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Python 3 (the bridge is stdlib-only) --------------------------------
have python3 || die "python3 not found. Install Xcode CLT (xcode-select --install), Homebrew Python, or your distro's python3, then re-run."
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

# --- 2. OpenCode CLI --------------------------------------------------------
if ! have opencode; then
  if have brew; then
    info "OpenCode not found - installing via Homebrew..."
    brew install sst/tap/opencode || brew install opencode
  else
    info "OpenCode not found - installing via the official install script..."
    have curl || die "curl not found. Install OpenCode manually from https://opencode.ai, then re-run."
    curl -fsSL https://opencode.ai/install | bash
    # The install script drops the binary in ~/.opencode/bin; surface it for this shell.
    export PATH="$HOME/.opencode/bin:$PATH"
  fi
fi
have opencode || die "'opencode' still not on PATH after install - open a new shell (or add ~/.opencode/bin to PATH) and re-run."
ok "OpenCode CLI $(opencode --version 2>&1 | head -1)"

# --- 3. Verify the model catalogue is reachable -----------------------------
info "Checking the free model catalogue (opencode models opencode)..."
FREE_MODELS="$(opencode models opencode 2>/dev/null | grep -c . || true)"
if [ "${FREE_MODELS:-0}" -eq 0 ]; then
  warn "Could not list opencode zen models."
  echo "     The bridge will fall back to its built-in list, but verify with:"
  echo "       opencode models opencode"
  echo "       opencode providers list      # credentials OpenCode can see"
else
  ok "$FREE_MODELS opencode zen models visible (free tier)"
fi

# --- 4. Offline logic checks ------------------------------------------------
BRIDGE_SELFCHECK=1 python3 "$SCRIPT_DIR/opencode_bridge.py" >/dev/null && ok "bridge selfcheck passed"

# --- 5. Register the bridge as a user service ------------------------------
if [ "$NO_SERVICE" -eq 1 ]; then
  info "--no-service set: skipping service registration."
  echo "     Start the bridge manually with:  ./run-bridge.sh"
else
  info "Registering the bridge as a user service (auto-start at login)..."
  "$SCRIPT_DIR/run-bridge.sh" install-service
fi

ok "Done. Endpoint: http://127.0.0.1:${BRIDGE_PORT}/v1  (model: ${MODEL})"
echo
echo "Next steps:"
echo "  ./run-bridge.sh test             # health check + a live completion"
echo "  ./run-bridge.sh models           # what the endpoint advertises"
echo "  ./run-bridge.sh service-status   # service state"
echo "  ./run-bridge.sh logs             # tail the service log"
echo
echo "In Hermes: Settings -> Model -> Custom endpoint"
echo "  Base URL: http://127.0.0.1:${BRIDGE_PORT}/v1"
echo "  API key:  (leave empty unless you set OPENCODE_BRIDGE_API_KEY)"
echo "  Model:    ${MODEL}"
