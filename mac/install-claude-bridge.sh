#!/usr/bin/env bash
# install-claude-bridge.sh - one-shot macOS bootstrap for the Claude Code Bridge.
#
# Installs everything a fresh Mac needs to expose an OpenAI-compatible endpoint
# backed by your authenticated Claude Code CLI:
#
#   1. Node.js LTS      (via Homebrew, if missing)
#   2. Claude Code CLI  (npm i -g @anthropic-ai/claude-code)
#   3. The bridge       (launchd LaunchAgent, auto-starts at login)
#
# Idempotent - safe to re-run. Nothing here needs sudo: the LaunchAgent runs as
# YOU, so it inherits your interactive `claude` login.
#
# Usage (from this folder):
#   ./install-claude-bridge.sh              # full install + start the service
#   ./install-claude-bridge.sh --no-service # install deps only, don't register the service
#
# Endpoint after install: http://127.0.0.1:18181/v1  (model: claude-opus-4-8)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NO_SERVICE=0
[ "${1:-}" = "--no-service" ] && NO_SERVICE=1

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Python 3 (the bridge is stdlib-only; macOS ships python3) -----------
have python3 || die "python3 not found. Install Xcode CLT (xcode-select --install) or Homebrew Python, then re-run."
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

# --- 2. Node.js LTS ---------------------------------------------------------
if ! have node; then
  info "Node.js not found - installing via Homebrew..."
  have brew || die "Homebrew not found. Install from https://brew.sh (or install Node LTS from https://nodejs.org), then re-run."
  brew install node
fi
ok "node $(node --version)"

# --- 3. Claude Code CLI -----------------------------------------------------
if ! have claude; then
  info "Installing Claude Code CLI (npm i -g @anthropic-ai/claude-code)..."
  npm install -g "@anthropic-ai/claude-code@latest"
fi
have claude || die "'claude' still not on PATH after install - open a new shell and re-run."
ok "Claude Code CLI $(claude --version 2>&1 | head -1)"

# --- 4. Authenticate --------------------------------------------------------
info "Verifying Claude Code is authenticated..."
if ! claude --version >/dev/null 2>&1; then
  warn "Claude Code is not authenticated yet."
  echo "     Run:  claude   (complete the browser login), then re-run this script."
  exit 1
fi
ok "Claude Code authenticated"

# --- 5. Register the bridge as a launchd service ----------------------------
if [ "$NO_SERVICE" -eq 1 ]; then
  info "--no-service set: skipping LaunchAgent registration."
  echo "     Start the bridge manually with:  ./run-bridge.sh"
else
  info "Registering the bridge as a launchd LaunchAgent (auto-start at login)..."
  "$SCRIPT_DIR/run-bridge.sh" install-service
fi

ok "Done. Endpoint: http://127.0.0.1:18181/v1  (model: claude-opus-4-8)"
echo
echo "Next steps:"
echo "  ./run-bridge.sh test             # health check + a live completion"
echo "  ./run-bridge.sh service-status   # LaunchAgent state"
echo "  ./run-bridge.sh logs             # tail the service log"
