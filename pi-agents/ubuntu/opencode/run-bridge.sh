#!/usr/bin/env bash
#
# run-bridge.sh — pi-agents backend: OpenCode FREE models (Ubuntu / Linux).
#
# Hermes → pi_bridge.py (:18484) → pi (tools + Codex-style approvals) → pure-LLM OpenCode
# bridge (:18385, opencode/pure-llm.json) → opencode/mimo-v2.5-free & friends.
#
# Both bridges run as systemd --user services with linger on, so the endpoints are back
# automatically after a reboot without anyone logging in.
#
# Usage (from this folder):
#   ./run-bridge.sh                 # foreground pi bridge on 127.0.0.1:18484
#   ./run-bridge.sh upstream        # foreground pure-LLM OpenCode bridge on :18385
#   ./run-bridge.sh test            # /health + a safe completion (mkdir+ls) + a held one (rm -rf)
#   ./run-bridge.sh approve         # replays the rm -rf turn with "approve" → it runs
#   ./run-bridge.sh models          # models the pi bridge advertises
#   ./run-bridge.sh selfcheck       # offline checks (pi_bridge.py + guardrail policy)
#   ./run-bridge.sh install-service # both bridges as enabled systemd --user services + linger
#   ./run-bridge.sh uninstall-service | service-status | restart | logs | journal
#
# systemd units: pi-bridge-opencode.service  pi-upstream-opencode.service  (--user)
#
# Config (env or a .env next to this script; see .env.example) — baked in at install:
#   BRIDGE_PORT 18484   UPSTREAM_PORT 18385   PI_BRIDGE_MODEL opencode/mimo-v2.5-free
#   PI_BRIDGE_CWD $HOME (fallback; the Hermes project dir wins)   PI_BRIDGE_APPROVAL ask|allow|deny
#   PI_BRIDGE_API_KEY   PI_BRIDGE_TIMEOUT 600   PI_GUARDRAILS_CONFIG ./guardrails.json
set -euo pipefail

BACKEND_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$BACKEND_DIR/.env" ] && { set -a; . "$BACKEND_DIR/.env"; set +a; }

BACKEND_NAME="opencode"
PROVIDER_ID="opencode-bridge"
BRIDGE_PORT="${BRIDGE_PORT:-18484}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18385}"
MODEL="${PI_BRIDGE_MODEL:-opencode/mimo-v2.5-free}"
# Plain systemd unit stems (the reverse-DNS labels in macos/ are launchd conventions).
LABEL="pi-bridge-opencode"
UPSTREAM_LABEL="pi-upstream-opencode"
OPENCODE_LAUNCHER="$BACKEND_DIR/../../../opencode/hermes-desktop/run-bridge.sh"
PURE_LLM_CONFIG="$BACKEND_DIR/opencode/pure-llm.json"
UPSTREAM_ENV="${OPENCODE_BIN:+OPENCODE_BIN=$OPENCODE_BIN}"

upstream_require() {
  command -v opencode >/dev/null 2>&1 || [ -x "${OPENCODE_BIN:-}" ] || [ -x "$HOME/.opencode/bin/opencode" ] \
    || { echo "[pi-bridge] error: opencode not on PATH — curl -fsSL https://opencode.ai/install | bash" >&2; exit 1; }
  [ -x "$OPENCODE_LAUNCHER" ] || { echo "[pi-bridge] error: $OPENCODE_LAUNCHER missing" >&2; exit 1; }
  [ -f "$PURE_LLM_CONFIG" ] || { echo "[pi-bridge] error: $PURE_LLM_CONFIG missing (broken symlink into ../../macos/opencode/opencode?)" >&2; exit 1; }
}
upstream_run() {
  BRIDGE_PORT="$UPSTREAM_PORT" OPENCODE_CONFIG="$PURE_LLM_CONFIG" OPENCODE_BRIDGE_LABEL="$UPSTREAM_LABEL" exec "$OPENCODE_LAUNCHER" run
}

. "$BACKEND_DIR/../common/launcher.sh"
