#!/usr/bin/env bash
# launcher.sh — shared launcher/service logic for every pi-agents backend on Ubuntu/Linux.
#
# Same command surface as macos/common/launcher.sh, but the service layer is systemd --user
# only: hardened units, journald + file logs, `loginctl enable-linger` so the endpoints come
# back after a reboot without anyone logging in.
#
# A backend's run-bridge.sh sets a few variables, defines `upstream_run` (how to start its
# pure-LLM upstream bridge in the foreground) and then sources this file, which provides:
#
#   run | upstream | test | approve | models | selfcheck | install-service |
#   uninstall-service | service-status | restart | logs | journal | help
#
# Required from the backend (before sourcing):
#   BACKEND_NAME        e.g. claude-code        BACKEND_DIR   the backend folder
#   BRIDGE_PORT         pi bridge port          UPSTREAM_PORT upstream (pure-LLM) bridge port
#   PROVIDER_ID         pi provider id          MODEL         default model id
#   LABEL / UPSTREAM_LABEL   systemd unit stems (plain names, no reverse-DNS on Linux)
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

[ "$(uname -s)" = "Linux" ] || { echo "[pi-bridge] error: this is the Ubuntu/Linux tree — on macOS use ../../macos/${BACKEND_NAME}/" >&2; exit 1; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "[pi-bridge] error: python3 not found — sudo apt-get install -y python3" >&2; exit 1; }
PI_BIN="${PI_BIN:-$(command -v pi || echo "$HOME/.local/bin/pi")}"

shell_quote() { local q; printf -v q '%q' "$1"; printf '%s' "$q"; }

require_bins() {
  [ -x "$PI_BIN" ] || { echo "[pi-bridge] error: pi not found — npm install -g @earendil-works/pi-coding-agent (or set PI_BIN)" >&2; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo "[pi-bridge] error: systemctl not found — this tree needs systemd" >&2; exit 1; }
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
  echo "[pi-bridge] config (${BACKEND_NAME}, ubuntu):"
  echo "  endpoint:       http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1"
  echo "  upstream:       ${PI_UPSTREAM_BASE_URL}  (pure-LLM ${BACKEND_NAME} bridge)"
  echo "  provider/model: ${PROVIDER_ID} / ${MODEL}"
  echo "  pi:             ${PI_BIN}"
  echo "  cwd (tools):    ${PI_BRIDGE_CWD}  (+ the Hermes project directory when sent)"
  echo "  approval:       ${PI_BRIDGE_APPROVAL}   (ask = held until you reply 'approve'; allow = run all; deny = read-only)"
  echo "  guardrails:     ${PI_GUARDRAILS_CONFIG}"
  echo "  audit log:      ${PI_GUARDRAILS_AUDIT}"
  echo "  units:          ${LABEL}.service  ${UPSTREAM_LABEL}.service  (systemd --user)"
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
# systemd --user starts these with a near-empty environment, so every value the bridges need
# is baked in here (absolute PATH included: ~/.local/bin and the npm global bin are NOT on the
# PATH of a unit started at boot).
write_runners() {
  mkdir -p "$SERVICE_DIR"; export_env
  local npm_bin; npm_bin="$( (npm prefix -g 2>/dev/null || true) )"; [ -n "$npm_bin" ] && npm_bin="$npm_bin/bin"
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service. Do not edit — re-run install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=%s:%s:%s:%s/.local/bin:/usr/local/bin:/usr/bin:/bin\n' \
      "$(shell_quote "$(dirname "$PY")")" "$(shell_quote "$(dirname "$PI_BIN")")" \
      "$(shell_quote "${npm_bin:-/usr/local/bin}")" "$(shell_quote "$HOME")"
    printf 'export HOME=%s\n' "$(shell_quote "$HOME")"
    for v in PI_BIN BRIDGE_HOST BRIDGE_PORT PI_UPSTREAM_BASE_URL PI_BRIDGE_PROVIDER_ID PI_BRIDGE_MODEL PI_BRIDGE_CWD PI_BRIDGE_APPROVAL PI_GUARDRAILS_CONFIG PI_GUARDRAILS_AUDIT PI_BRIDGE_API_KEY PI_UPSTREAM_API_KEY PI_BRIDGE_TIMEOUT PI_BRIDGE_MAX_CONCURRENCY PI_BRIDGE_SHOW_TOOLS PI_BRIDGE_SHOW_OUTPUT PI_BRIDGE_KEEPALIVE PI_UPSTREAM_NATIVE_TOOLS PI_BRIDGE_TOOLS PI_BRIDGE_SYSTEM_PROMPT PI_BRIDGE_CWD_FROM_PROMPT; do
      [ -n "${!v:-}" ] && printf 'export %s=%s\n' "$v" "$(shell_quote "${!v}")"
    done
    printf 'exec %s %s\n' "$(shell_quote "$PY")" "$(shell_quote "$COMMON_DIR/pi_bridge.py")"
  } > "$SERVICE_DIR/run-pi-bridge.sh"
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service. Do not edit — re-run install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=%s:%s:%s/.local/bin:%s/.opencode/bin:/usr/local/bin:/usr/bin:/bin\n' \
      "$(shell_quote "$(dirname "$PY")")" "$(shell_quote "${npm_bin:-/usr/local/bin}")" \
      "$(shell_quote "$HOME")" "$(shell_quote "$HOME")"
    printf 'export HOME=%s\n' "$(shell_quote "$HOME")"
    local kv
    for kv in ${UPSTREAM_ENV:-}; do printf 'export %s=%s\n' "${kv%%=*}" "$(shell_quote "${kv#*=}")"; done
    printf 'exec %s upstream\n' "$(shell_quote "$BACKEND_DIR/run-bridge.sh")"
  } > "$SERVICE_DIR/run-upstream.sh"
  chmod 755 "$SERVICE_DIR"/run-*.sh
}

# ── systemd --user units ──────────────────────────────────────────────────────
unit_path() { printf '%s/.config/systemd/user/%s.service' "$HOME" "$1"; }

install_systemd_one() { # label runner log description [after-unit]
  local unit; unit="$(unit_path "$1")"; mkdir -p "$(dirname "$unit")"
  {
    printf '[Unit]\n'
    printf 'Description=%s\n' "$4"
    printf 'Documentation=file://%s/README.md\n' "$BACKEND_DIR"
    printf 'Wants=network-online.target\nAfter=network-online.target\n'
    [ -n "${5:-}" ] && printf 'After=%s.service\nWants=%s.service\n' "$5" "$5"
    printf 'StartLimitIntervalSec=300\nStartLimitBurst=10\n\n'
    printf '[Service]\nType=simple\n'
    printf 'ExecStart=%s\n' "$2"
    printf 'WorkingDirectory=%s\n' "$HOME"
    printf 'Restart=always\nRestartSec=3\nTimeoutStopSec=20\nKillMode=mixed\n'
    # journald keeps the structured history; the append: files keep `run-bridge.sh logs` working.
    printf 'StandardOutput=append:%s\nStandardError=append:%s\n' "$3" "$3"
    printf 'SyslogIdentifier=%s\n' "$1"
    printf 'NoNewPrivileges=true\nPrivateTmp=false\n\n'
    printf '[Install]\nWantedBy=default.target\n'
  } > "$unit"
  systemctl --user daemon-reload
  systemctl --user reset-failed "$1.service" >/dev/null 2>&1 || true
  systemctl --user enable "$1.service" >/dev/null
  systemctl --user restart "$1.service"
  echo "[pi-bridge] systemd --user: $1.service → $unit (log $3)"
}
uninstall_systemd_one() { systemctl --user disable --now "$1.service" >/dev/null 2>&1 || true; rm -f "$(unit_path "$1")"; }

# Survive reboot AND logout: without linger, systemd --user is torn down when the last session ends.
enable_linger() {
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" = "yes" ]; then
    echo "[pi-bridge] linger already enabled for $USER (services survive reboot/logout)"
    return 0
  fi
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    echo "[pi-bridge] linger enabled for $USER (services survive reboot/logout)"
  else
    echo "[pi-bridge] warning: could not enable linger — run:  sudo loginctl enable-linger $USER" >&2
    echo "[pi-bridge]          without it the endpoints stop when you log out and do not return after reboot." >&2
  fi
}

# A leftover foreground copy makes the service crash-loop on "address in use".
listener_pid() { # port
  local pid
  pid="$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  [ -n "$pid" ] || pid="$(lsof -tnP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  printf '%s' "$pid"
}
stop_strays() {
  local port pid
  for port in "$UPSTREAM_PORT" "$BRIDGE_PORT"; do
    pid="$(listener_pid "$port")"
    [ -n "$pid" ] || continue
    if ! ps -o args= -p "$pid" 2>/dev/null | grep -q "pi-bridge-${BACKEND_NAME}/run-"; then
      echo "[pi-bridge] port $port held by a non-service process (pid $pid) — stopping it"
      kill "$pid" 2>/dev/null || true; sleep 1
      pid="$(listener_pid "$port")"; [ -n "$pid" ] && { kill -9 "$pid" 2>/dev/null || true; sleep 1; }
    fi
  done
  return 0
}

wait_health() { # port label
  local i; printf '[pi-bridge] waiting for %s http://127.0.0.1:%s/health ' "$2" "$1"
  for i in $(seq 1 240); do curl -fsS "http://127.0.0.1:$1/health" >/dev/null 2>&1 && { echo; return 0; }; printf '.'; sleep 0.5; done
  echo; return 1
}

cmd_install_service() {
  require_bins; stop_strays; write_runners
  install_systemd_one "$UPSTREAM_LABEL" "$SERVICE_DIR/run-upstream.sh" "$UPSTREAM_LOG" \
    "pi-agents ${BACKEND_NAME}: pure-LLM upstream bridge (:${UPSTREAM_PORT})"
  install_systemd_one "$LABEL" "$SERVICE_DIR/run-pi-bridge.sh" "$LOG_FILE" \
    "pi-agents ${BACKEND_NAME}: pi bridge, Hermes custom endpoint (:${BRIDGE_PORT})" "$UPSTREAM_LABEL"
  enable_linger
  wait_health "$UPSTREAM_PORT" upstream || echo "[pi-bridge] warning: upstream not healthy yet (see $UPSTREAM_LOG)"
  if wait_health "$BRIDGE_PORT" "pi bridge"; then
    curl -fsS -X POST "http://127.0.0.1:${BRIDGE_PORT}/v1/models/refresh" >/dev/null 2>&1 || true
    print_config; echo; cmd_test || echo "[pi-bridge] (endpoint up; live test failed — check: $0 logs)"
  else
    echo "[pi-bridge] warning: pi bridge not healthy after 120s — tail of logs:" >&2
    tail -n 15 "$UPSTREAM_LOG" "$LOG_FILE" >&2 || true
    systemctl --user status "$LABEL.service" "$UPSTREAM_LABEL.service" --no-pager >&2 || true
    exit 1
  fi
}
cmd_uninstall_service() {
  uninstall_systemd_one "$LABEL"; uninstall_systemd_one "$UPSTREAM_LABEL"
  systemctl --user daemon-reload
  rm -f "$SERVICE_DIR"/run-*.sh
  echo "[pi-bridge] ${BACKEND_NAME} services removed (linger left enabled; disable with: loginctl disable-linger $USER)"
}
cmd_service_status() {
  systemctl --user status "$UPSTREAM_LABEL.service" "$LABEL.service" --no-pager 2>/dev/null || echo "[pi-bridge] not installed"
  echo
  printf '[pi-bridge] enabled at boot: %s / %s   linger: %s\n' \
    "$(systemctl --user is-enabled "$UPSTREAM_LABEL.service" 2>/dev/null || echo no)" \
    "$(systemctl --user is-enabled "$LABEL.service" 2>/dev/null || echo no)" \
    "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
  printf '[pi-bridge] /health upstream :%s → %s   pi bridge :%s → %s\n' \
    "$UPSTREAM_PORT" "$(curl -fsS -m 3 "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 && echo ok || echo DOWN)" \
    "$BRIDGE_PORT"   "$(curl -fsS -m 3 "http://127.0.0.1:${BRIDGE_PORT}/health"   >/dev/null 2>&1 && echo ok || echo DOWN)"
}
cmd_restart() {
  systemctl --user restart "$UPSTREAM_LABEL.service" "$LABEL.service"
  wait_health "$UPSTREAM_PORT" upstream || true
  wait_health "$BRIDGE_PORT" "pi bridge" || true
  cmd_service_status
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
  restart)            cmd_restart ;;
  logs)               touch "$LOG_FILE" "$UPSTREAM_LOG"; tail -f "$LOG_FILE" "$UPSTREAM_LOG" ;;
  journal)            journalctl --user -u "$LABEL.service" -u "$UPSTREAM_LABEL.service" -n 200 -f ;;
  help|-h|--help)     awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$BACKEND_DIR/run-bridge.sh" ;;
  *) echo "[pi-bridge] unknown command: ${1:-} (try: $0 help)" >&2; exit 1 ;;
esac
