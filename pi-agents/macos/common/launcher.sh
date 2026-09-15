#!/usr/bin/env bash
# launcher.sh — shared launcher/service logic for every pi-agents backend (macOS / Linux).
#
# A backend's run-bridge.sh sets a few variables, defines `upstream_run` (how to start its
# pure-LLM upstream bridge in the foreground) and then sources this file, which provides:
#
#   run | upstream | test | approve | models | selfcheck | install-service |
#   uninstall-service | service-status | logs | help
#
# Required from the backend (before sourcing):
#   BACKEND_NAME        e.g. opencode            BACKEND_DIR   the backend folder
#   BRIDGE_PORT         pi bridge port           UPSTREAM_PORT upstream (pure-LLM) bridge port
#   PROVIDER_ID         pi provider id           MODEL         default model id
#   LABEL / UPSTREAM_LABEL   launchd labels / systemd unit stems
#   upstream_run()      exec's the upstream bridge in the foreground (env already exported)
#   upstream_require()  exits non-zero with a message when the upstream CLI is missing
# Optional: UPSTREAM_ENV (space-separated NAME=VALUE pairs baked into the upstream runner),
#           RISKY_PROMPT / SAFE_PROMPT for `test`.
set -euo pipefail

COMMON_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
API_KEY="${PI_BRIDGE_API_KEY:-}"
LOG_FILE="${PI_BRIDGE_LOG:-$HOME/.pi-bridge-${BACKEND_NAME}.log}"
UPSTREAM_LOG="${PI_UPSTREAM_LOG:-$HOME/.pi-upstream-${BACKEND_NAME}.log}"
SERVICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-bridge-${BACKEND_NAME}"
# `test` exercises the default dangerous-only profile: everyday work runs, rm -rf is held.
SAFE_PROMPT="${SAFE_PROMPT:-create an empty directory named pi-bridge-approval-test here, then list the current directory}"
RISKY_PROMPT="${RISKY_PROMPT:-delete the directory pi-bridge-approval-test using rm -rf}"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "[pi-bridge] error: python3 not found" >&2; exit 1; }
PI_BIN="${PI_BIN:-$(command -v pi || echo "$HOME/.local/bin/pi")}"

shell_quote() { local q; printf -v q '%q' "$1"; printf '%s' "$q"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
os_kind() { case "$(uname -s)" in Darwin) echo mac;; Linux) echo linux;; *) echo other;; esac; }

require_bins() {
  [ -x "$PI_BIN" ] || { echo "[pi-bridge] error: pi not found — npm install -g @earendil-works/pi-coding-agent (or set PI_BIN)" >&2; exit 1; }
  upstream_require
}

# Environment shared by the foreground run and the generated service runner.
export_env() {
  export PI_BIN BRIDGE_HOST BRIDGE_PORT
  export PI_UPSTREAM_BASE_URL="${PI_UPSTREAM_BASE_URL:-http://127.0.0.1:${UPSTREAM_PORT}/v1}"
  export PI_BRIDGE_PROVIDER_ID="$PROVIDER_ID"
  export PI_BRIDGE_MODEL="$MODEL"
  export PI_BRIDGE_CWD="${PI_BRIDGE_CWD:-$HOME}"
  export PI_BRIDGE_APPROVAL="${PI_BRIDGE_APPROVAL:-ask}"
  export PI_GUARDRAILS_CONFIG="${PI_GUARDRAILS_CONFIG:-$BACKEND_DIR/guardrails.json}"
  export PI_GUARDRAILS_AUDIT="${PI_GUARDRAILS_AUDIT:-$HOME/.pi-bridge-audit.jsonl}"
  [ -n "$API_KEY" ] && export PI_BRIDGE_API_KEY="$API_KEY"
  return 0
}

print_config() {
  export_env
  echo "[pi-bridge] config (${BACKEND_NAME}):"
  echo "  endpoint:       http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1"
  echo "  upstream:       ${PI_UPSTREAM_BASE_URL}  (pure-LLM ${BACKEND_NAME} bridge)"
  echo "  provider/model: ${PROVIDER_ID} / ${MODEL}"
  echo "  pi:             ${PI_BIN}"
  echo "  cwd (tools):    ${PI_BRIDGE_CWD}  (+ the Hermes project directory when sent)"
  echo "  approval:       ${PI_BRIDGE_APPROVAL}   (ask = held until you reply 'approve'; allow = run all; deny = read-only)"
  echo "  guardrails:     ${PI_GUARDRAILS_CONFIG}"
  echo "  audit log:      ${PI_GUARDRAILS_AUDIT}"
  echo "  api key:        $([ -n "$API_KEY" ] && echo required || echo not required)"
}

cmd_run() {
  require_bins; export_env; print_config
  curl -fsS "${PI_UPSTREAM_BASE_URL%/v1}/health" >/dev/null 2>&1 || \
    echo "[pi-bridge] note: upstream ${PI_UPSTREAM_BASE_URL} is not answering — start it with: $0 upstream"
  exec "$PY" "$COMMON_DIR/pi_bridge.py"
}

cmd_upstream() { require_bins; echo "[pi-bridge] starting pure-LLM ${BACKEND_NAME} bridge on :${UPSTREAM_PORT}"; upstream_run; }

post() { # post <json>
  local -a auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer ${API_KEY}")
  curl -sS --fail-with-body --max-time 660 ${auth[@]+"${auth[@]}"} -H 'content-type: application/json' \
    "http://127.0.0.1:${BRIDGE_PORT}/v1/chat/completions" -d "$1" \
    | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"] if "choices" in d else d)'
}

json_str() { "$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

cmd_test() {
  echo "[pi-bridge] GET /health"; curl -fsS "http://127.0.0.1:${BRIDGE_PORT}/health"; echo
  echo "[pi-bridge] everyday call — expect pi to run mkdir + ls itself, no approval:"
  post "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":$(json_str "$SAFE_PROMPT")}]}"
  echo; echo "[pi-bridge] dangerous call — expect an approval card, directory still present:"
  post "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":$(json_str "$RISKY_PROMPT")}]}"
}

cmd_approve() {
  echo "[pi-bridge] replaying the held turn with 'approve' — expect rm -rf to run:"
  post "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":$(json_str "$RISKY_PROMPT")},{\"role\":\"assistant\",\"content\":\"Approval required\\n\\n\`\`\`bash\\nrm -rf pi-bridge-approval-test\\n\`\`\`\\nReply approve to run it.\"},{\"role\":\"user\",\"content\":\"approve\"}]}"
}

cmd_models() {
  curl -fsS "http://127.0.0.1:${BRIDGE_PORT}/v1/models" | "$PY" -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin)["data"]]'
}

cmd_selfcheck() {
  BRIDGE_SELFCHECK=1 "$PY" "$COMMON_DIR/pi_bridge.py"
  PI_GUARDRAILS_CONFIG="$BACKEND_DIR/guardrails.json" node "$COMMON_DIR/extensions/guardrails/selfcheck.mjs" | tail -1
}

# ── service runners ───────────────────────────────────────────────────────────
write_runners() {
  mkdir -p "$SERVICE_DIR"; export_env
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=%s:%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"\n' "$(shell_quote "$(dirname "$PY")")" "$(shell_quote "$(dirname "$PI_BIN")")"
    for v in PI_BIN BRIDGE_HOST BRIDGE_PORT PI_UPSTREAM_BASE_URL PI_BRIDGE_PROVIDER_ID PI_BRIDGE_MODEL PI_BRIDGE_CWD PI_BRIDGE_APPROVAL PI_GUARDRAILS_CONFIG PI_GUARDRAILS_AUDIT PI_BRIDGE_API_KEY PI_UPSTREAM_API_KEY PI_BRIDGE_TIMEOUT PI_BRIDGE_MAX_CONCURRENCY PI_BRIDGE_SHOW_TOOLS PI_BRIDGE_SHOW_OUTPUT PI_BRIDGE_KEEPALIVE PI_UPSTREAM_NATIVE_TOOLS PI_BRIDGE_TOOLS PI_BRIDGE_SYSTEM_PROMPT PI_BRIDGE_CWD_FROM_PROMPT; do
      [ -n "${!v:-}" ] && printf 'export %s=%s\n' "$v" "$(shell_quote "${!v}")"
    done
    printf 'exec %s %s\n' "$(shell_quote "$PY")" "$(shell_quote "$COMMON_DIR/pi_bridge.py")"
  } > "$SERVICE_DIR/run-pi-bridge.sh"
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=%s:/opt/homebrew/bin:/usr/local/bin:%s/.local/bin:/usr/bin:/bin:"$PATH"\n' "$(shell_quote "$(dirname "$PY")")" "$(shell_quote "$HOME")"
    local kv
    for kv in ${UPSTREAM_ENV:-}; do printf 'export %s=%s\n' "${kv%%=*}" "$(shell_quote "${kv#*=}")"; done
    printf 'exec %s upstream\n' "$(shell_quote "$BACKEND_DIR/run-bridge.sh")"
  } > "$SERVICE_DIR/run-upstream.sh"
  chmod 755 "$SERVICE_DIR"/run-*.sh
}

plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$1"; }
install_launchd_one() { # label runner log
  local plist; plist="$(plist_path "$1")"; mkdir -p "$(dirname "$plist")"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$1"
    printf '  <key>ProgramArguments</key><array><string>%s</string></array>\n' "$(xml_escape "$2")"
    printf '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n'
    printf '  <key>StandardOutPath</key><string>%s</string>\n  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$3")" "$(xml_escape "$3")"
    printf '</dict></plist>\n'
  } > "$plist"
  local domain="gui/$(id -u)" i
  launchctl bootout "$domain/$1" >/dev/null 2>&1 || true
  for i in $(seq 1 40); do launchctl print "$domain/$1" >/dev/null 2>&1 || break; sleep 0.25; done
  launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist"
  launchctl enable "$domain/$1" >/dev/null 2>&1 || true
  # No `kickstart -k` here: bootstrap already started it (RunAtLoad); a kickstart would SIGTERM
  # that fresh instance and race the health check / live test with the restart.
  echo "[pi-bridge] launchd: $1 → $plist (log $3)"
}
uninstall_launchd_one() { launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 || true; rm -f "$(plist_path "$1")"; }

unit_path() { printf '%s/.config/systemd/user/%s.service' "$HOME" "$1"; }
install_systemd_one() { # label runner log description
  local unit; unit="$(unit_path "$1")"; mkdir -p "$(dirname "$unit")"
  printf '[Unit]\nDescription=%s\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=%s\nRestart=always\nRestartSec=3\nStandardOutput=append:%s\nStandardError=append:%s\n\n[Install]\nWantedBy=default.target\n' "$4" "$2" "$3" "$3" > "$unit"
  systemctl --user daemon-reload; systemctl --user enable --now "$1.service"
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  echo "[pi-bridge] systemd: $1 → $unit (log $3)"
}
uninstall_systemd_one() { systemctl --user disable --now "$1.service" >/dev/null 2>&1 || true; rm -f "$(unit_path "$1")"; }

# A leftover foreground copy makes the service crash-loop on "address in use".
stop_strays() {
  local port pid
  for port in "$UPSTREAM_PORT" "$BRIDGE_PORT"; do
    pid="$(lsof -tnP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    [ -n "$pid" ] || continue
    if ! ps -o command= -p "$pid" | grep -q "pi-bridge-${BACKEND_NAME}/run-"; then
      echo "[pi-bridge] port $port held by a non-service process (pid $pid) — stopping it"
      kill "$pid" 2>/dev/null || true; sleep 1
    fi
  done
}

wait_health() { # port label
  local i; printf '[pi-bridge] waiting for %s http://127.0.0.1:%s/health ' "$2" "$1"
  for i in $(seq 1 240); do curl -fsS "http://127.0.0.1:$1/health" >/dev/null 2>&1 && { echo; return 0; }; printf '.'; sleep 0.5; done
  echo; return 1
}

cmd_install_service() {
  require_bins; stop_strays; write_runners
  case "$(os_kind)" in
    mac)   install_launchd_one "$UPSTREAM_LABEL" "$SERVICE_DIR/run-upstream.sh" "$UPSTREAM_LOG"
           install_launchd_one "$LABEL" "$SERVICE_DIR/run-pi-bridge.sh" "$LOG_FILE" ;;
    linux) install_systemd_one "$UPSTREAM_LABEL" "$SERVICE_DIR/run-upstream.sh" "$UPSTREAM_LOG" "pi-agents ${BACKEND_NAME}: pure-LLM upstream bridge"
           install_systemd_one "$LABEL" "$SERVICE_DIR/run-pi-bridge.sh" "$LOG_FILE" "pi-agents ${BACKEND_NAME}: pi bridge (Hermes custom endpoint)" ;;
    *) echo "[pi-bridge] error: unsupported OS for auto-service; use: $0 upstream  and  $0 run" >&2; exit 1 ;;
  esac
  wait_health "$UPSTREAM_PORT" upstream || echo "[pi-bridge] warning: upstream not healthy yet (see $UPSTREAM_LOG)"
  if wait_health "$BRIDGE_PORT" "pi bridge"; then
    curl -fsS -X POST "http://127.0.0.1:${BRIDGE_PORT}/v1/models/refresh" >/dev/null 2>&1 || true
    print_config; echo; cmd_test || echo "[pi-bridge] (endpoint up; live test failed — check: $0 logs)"
  else
    echo "[pi-bridge] warning: pi bridge not healthy after 120s — tail of logs:" >&2; tail -n 15 "$UPSTREAM_LOG" "$LOG_FILE" >&2 || true; exit 1
  fi
}
cmd_uninstall_service() {
  case "$(os_kind)" in
    mac)   uninstall_launchd_one "$LABEL"; uninstall_launchd_one "$UPSTREAM_LABEL" ;;
    linux) uninstall_systemd_one "$LABEL"; uninstall_systemd_one "$UPSTREAM_LABEL"; systemctl --user daemon-reload ;;
  esac
  rm -f "$SERVICE_DIR"/run-*.sh; echo "[pi-bridge] ${BACKEND_NAME} services removed"
}
cmd_service_status() {
  case "$(os_kind)" in
    mac)   launchctl list 2>/dev/null | grep -E "$LABEL|$UPSTREAM_LABEL" || echo "[pi-bridge] not loaded" ;;
    linux) systemctl --user status "$LABEL.service" "$UPSTREAM_LABEL.service" --no-pager 2>/dev/null || echo "[pi-bridge] not installed" ;;
  esac
}

case "${1:-run}" in
  run)                cmd_run ;;
  upstream)           cmd_upstream ;;
  test)               cmd_test ;;
  approve)            cmd_approve ;;
  models)             cmd_models ;;
  selfcheck)          cmd_selfcheck ;;
  install-service)    cmd_install_service ;;
  uninstall-service)  cmd_uninstall_service ;;
  service-status)     cmd_service_status ;;
  logs)               touch "$LOG_FILE" "$UPSTREAM_LOG"; tail -f "$LOG_FILE" "$UPSTREAM_LOG" ;;
  help|-h|--help)     awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$BACKEND_DIR/run-bridge.sh" ;;
  *) echo "[pi-bridge] unknown command: ${1:-} (try: $0 help)" >&2; exit 1 ;;
esac
