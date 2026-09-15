#!/usr/bin/env bash
# install-lib.sh — shared one-shot bootstrap for every pi-agents backend.
#
# A backend's install.sh sets BACKEND_NAME / BACKEND_DIR, defines `backend_install_deps`
# (installs + verifies its upstream CLI) and sources this file. Steps:
#   1. Python 3   2. Node.js 20+ / npm   3. pi   4. backend deps   5. self-checks
#   6. both bridges registered as auto-start user services (launchd / systemd --user)
# Idempotent. No sudo. `--no-service` = deps + checks only. `--uninstall` = remove services.
set -euo pipefail

info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m      %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m    %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m   %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  --uninstall) exec "$BACKEND_DIR/run-bridge.sh" uninstall-service ;;
  --no-service) NO_SERVICE=1 ;;
  "") NO_SERVICE=0 ;;
  *) die "unknown flag: $1 (use --no-service or --uninstall)" ;;
esac

have python3 || die "python3 not found. macOS: xcode-select --install (or brew install python); Linux: your distro's python3."
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

if ! have npm; then
  if have brew; then info "Node.js not found — installing via Homebrew..."; brew install node
  else die "npm not found. Install Node.js 20+ (https://nodejs.org or your package manager), then re-run."; fi
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ required (found $(node --version 2>/dev/null || echo none))."
ok "node $(node --version)"

if ! have pi; then
  info "pi not found — installing @earendil-works/pi-coding-agent globally..."
  npm install -g @earendil-works/pi-coding-agent
  export PATH="$(npm prefix -g)/bin:$HOME/.local/bin:$PATH"
fi
have pi || die "'pi' still not on PATH — add $(npm prefix -g)/bin to PATH and re-run."
ok "pi $(pi --version 2>&1 | head -1)"

backend_install_deps

info "Running offline self-checks..."
"$BACKEND_DIR/run-bridge.sh" selfcheck >/dev/null && ok "pi_bridge.py + guardrail policy self-checks passed" || die "self-check failed — see output above"

if [ "$NO_SERVICE" -eq 1 ]; then
  info "--no-service: not registering services. Foreground alternative (two terminals):"
  echo "     ./run-bridge.sh upstream      # pure-LLM ${BACKEND_NAME} bridge :${UPSTREAM_PORT}"
  echo "     ./run-bridge.sh              # pi bridge :${BRIDGE_PORT}"
  exit 0
fi
info "Registering both bridges as auto-start user services..."
"$BACKEND_DIR/run-bridge.sh" install-service

echo
ok "Persistent. Hermes → Settings → Providers → Custom Endpoints → New endpoint"
echo "     Endpoint URL:  http://127.0.0.1:${BRIDGE_PORT}/v1"
echo "     Default Model: ${MODEL}"
echo "     Discover models ☑ → Test → Save → Use"
echo
echo "  ./run-bridge.sh service-status   # both services"
echo "  ./run-bridge.sh logs             # tail both logs"
echo "  ./run-bridge.sh test             # safe call + held call"
echo "  ./install.sh --uninstall         # remove the services"
