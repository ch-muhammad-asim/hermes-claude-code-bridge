#!/usr/bin/env bash
# install-lib.sh — shared one-shot bootstrap for every pi-agents backend on Ubuntu/Linux.
#
# A backend's install.sh sets BACKEND_NAME / BACKEND_DIR, defines `backend_install_deps`
# (installs + verifies its upstream CLI) and sources this file. Steps:
#   1. systemd --user usable   2. Python 3   3. Node.js 20+ / npm   4. pi   5. backend deps
#   6. self-checks   7. both bridges as enabled systemd --user services + linger (reboot-safe)
# Idempotent. Only the apt steps use sudo, and only when a package is actually missing.
#   ./install.sh | ./install.sh --no-service | ./install.sh --uninstall
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

[ "$(uname -s)" = "Linux" ] || die "this is the Ubuntu/Linux tree — on macOS run ../../macos/${BACKEND_NAME}/install.sh"
[ "$(id -u)" -ne 0 ] || die "do not run as root — these are per-user services; run as the desktop user that owns the Claude/OpenCode logins."

APT_UPDATED=0
apt_install() { # apt_install <pkg...> — only called for packages that are actually missing
  have apt-get || die "apt-get not found. Install manually: $*"
  if [ "$APT_UPDATED" -eq 0 ]; then info "sudo apt-get update"; sudo apt-get update -qq; APT_UPDATED=1; fi
  info "sudo apt-get install -y $*"
  sudo apt-get install -y -qq "$@"
}

# ── 1. systemd --user ─────────────────────────────────────────────────────────
have systemctl || die "systemctl not found — this tree needs systemd (Ubuntu 20.04+)."
systemctl --user show-environment >/dev/null 2>&1 \
  || die "systemd --user is not reachable (no user bus). Log in on a normal session, or set XDG_RUNTIME_DIR=/run/user/$(id -u)."
ok "systemd --user available"

# ── 2. base packages ──────────────────────────────────────────────────────────
MISSING=()
have python3 || MISSING+=(python3)
have curl    || MISSING+=(curl)
have ss      || MISSING+=(iproute2)
[ "${#MISSING[@]}" -eq 0 ] || apt_install "${MISSING[@]}"
have python3 || die "python3 still missing"
ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"

# ── 3. Node.js 20+ ────────────────────────────────────────────────────────────
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if ! have node || [ "$(node_major)" -lt 20 ]; then
  warn "Node.js 20+ required (found $(node --version 2>/dev/null || echo none))."
  info "Ubuntu's own 'nodejs' package is often too old — installing Node.js 20 LTS from NodeSource."
  have curl || apt_install curl
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  apt_install nodejs
fi
have npm || apt_install npm
[ "$(node_major)" -ge 20 ] || die "Node.js 20+ still not active (found $(node --version 2>/dev/null || echo none))."
ok "node $(node --version), npm $(npm --version)"

# npm's default global prefix (/usr/local or /usr) needs root. Give npm a user-owned prefix so
# `npm install -g` — and the systemd units that later call the installed binaries — need no sudo.
NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
if [ ! -w "$NPM_PREFIX/lib" ] 2>/dev/null || [ ! -w "$NPM_PREFIX" ]; then
  info "global npm prefix $NPM_PREFIX is not writable — switching to ~/.npm-global (no sudo needed)"
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global"
  NPM_PREFIX="$HOME/.npm-global"
fi
export PATH="$NPM_PREFIX/bin:$HOME/.local/bin:$PATH"
case ":${PATH}:" in *":$NPM_PREFIX/bin:"*) ;; esac
if ! grep -qs "$NPM_PREFIX/bin" "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
  warn "add this to your shell rc so 'pi' stays on your PATH in new terminals:"
  echo "       export PATH=\"$NPM_PREFIX/bin:\$HOME/.local/bin:\$PATH\""
fi

# ── 4. pi ─────────────────────────────────────────────────────────────────────
if ! have pi; then
  info "pi not found — installing @earendil-works/pi-coding-agent globally..."
  npm install -g @earendil-works/pi-coding-agent
fi
have pi || die "'pi' still not on PATH — add $NPM_PREFIX/bin to PATH and re-run."
ok "pi $(pi --version 2>&1 | head -1)"

# ── 5. backend-specific deps ──────────────────────────────────────────────────
backend_install_deps

# ── 6. self-checks ────────────────────────────────────────────────────────────
info "Running offline self-checks..."
"$BACKEND_DIR/run-bridge.sh" selfcheck >/dev/null && ok "pi_bridge.py + guardrail policy self-checks passed" || die "self-check failed — see output above"

# ── 7. services ───────────────────────────────────────────────────────────────
if [ "$NO_SERVICE" -eq 1 ]; then
  info "--no-service: not registering services. Foreground alternative (two terminals):"
  echo "     ./run-bridge.sh upstream      # pure-LLM ${BACKEND_NAME} bridge :${UPSTREAM_PORT}"
  echo "     ./run-bridge.sh              # pi bridge :${BRIDGE_PORT}"
  exit 0
fi
info "Registering both bridges as enabled systemd --user services..."
PI_BIN="$(command -v pi)" "$BACKEND_DIR/run-bridge.sh" install-service

echo
ok "Persistent across reboot. Hermes → Settings → Providers → Custom Endpoints → New endpoint"
echo "     Endpoint URL:  http://127.0.0.1:${BRIDGE_PORT}/v1"
echo "     Default Model: ${MODEL}"
echo "     Discover models ☑ → Test → Save → Use"
echo
echo "  ./run-bridge.sh service-status   # both units + /health + linger"
echo "  ./run-bridge.sh logs             # tail both log files"
echo "  ./run-bridge.sh journal          # follow journalctl --user for both units"
echo "  ./run-bridge.sh restart          # restart both, then re-check health"
echo "  ./run-bridge.sh test             # safe call + held call"
echo "  ./install.sh --uninstall         # remove the services"
