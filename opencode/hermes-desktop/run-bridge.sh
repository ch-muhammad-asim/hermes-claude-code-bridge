#!/usr/bin/env bash
#
# run-bridge.sh — launcher + service installer for the OpenCode Bridge (macOS / Linux).
#
# No Docker. The bridge is a single stdlib-only Python script that runs directly on the
# host against an already-authenticated `opencode`, exposing OpenCode's free models on
# an OpenAI-compatible endpoint the Hermes desktop app can use as a custom endpoint.
#
# Usage:
#   ./run-bridge.sh                 # run in the foreground (default 127.0.0.1:18282)
#   ./run-bridge.sh test            # curl /health + a chat completion
#   ./run-bridge.sh stream          # curl a streaming completion (SSE)
#   ./run-bridge.sh image FILE.png  # E2E vision test: send an image via base64
#                                   # (the bridge re-attaches it as an opencode
#                                   #  --file=... so free models can "see" it)
#   ./run-bridge.sh models          # list the models the bridge advertises
#   ./run-bridge.sh selfcheck       # offline logic checks (no opencode needed)
#   ./run-bridge.sh install-service # install + start a persistent auto-start service
#   ./run-bridge.sh uninstall-service
#   ./run-bridge.sh service-status
#   ./run-bridge.sh logs            # tail the service log
#
# The service is a *user* service (launchd LaunchAgent on macOS, systemd --user on
# Linux) so it inherits your authenticated OpenCode credentials. It restarts on crash
# and starts at login/boot (Linux uses lingering so it survives logout).
#
# Config (env or a .env next to this script) — baked into the service at install:
#   BRIDGE_HOST  default 127.0.0.1     BRIDGE_PORT default 18282
#   OPENCODE_BRIDGE_MODEL         default opencode/mimo-v2.5-free
#   OPENCODE_BRIDGE_CWD           default $HOME  (where opencode's tools operate)
#   OPENCODE_BRIDGE_API_KEY       (empty -> unauthenticated)
#   OPENCODE_BRIDGE_MAX_CONCURRENCY default 2    OPENCODE_BRIDGE_TIMEOUT default 300
#   OPENCODE_BRIDGE_AGENT / _VARIANT / _SHOW_TOOLS / _SHOW_REASONING
#   OPENCODE_BRIDGE_FREE_ONLY     default 1 (set 0 to also allow paid models)
#   OPENCODE_BIN  override the opencode path (else resolved from PATH)
#
# Portable to bash 3.2 (stock macOS): no mapfile/associative arrays.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${BRIDGE_PORT:-18282}"
MODEL="${OPENCODE_BRIDGE_MODEL:-opencode/mimo-v2.5-free}"
API_KEY="${OPENCODE_BRIDGE_API_KEY:-}"
BRIDGE_CWD="${OPENCODE_BRIDGE_CWD:-$HOME}"
MAX_CONCURRENCY="${OPENCODE_BRIDGE_MAX_CONCURRENCY:-2}"
QUEUE_WAIT="${OPENCODE_BRIDGE_QUEUE_WAIT:-30}"
TIMEOUT="${OPENCODE_BRIDGE_TIMEOUT:-300}"
FREE_ONLY="${OPENCODE_BRIDGE_FREE_ONLY:-1}"
AGENT="${OPENCODE_BRIDGE_AGENT:-}"
VARIANT="${OPENCODE_BRIDGE_VARIANT:-}"
SHOW_TOOLS="${OPENCODE_BRIDGE_SHOW_TOOLS:-0}"
SHOW_REASONING="${OPENCODE_BRIDGE_SHOW_REASONING:-0}"
BRIDGE_PY="$SCRIPT_DIR/opencode_bridge.py"
LOG_FILE="${OPENCODE_BRIDGE_LOG:-$HOME/.opencode-bridge.log}"
LABEL="com.hermes.opencode-bridge"   # launchd label / systemd unit stem
SERVICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-bridge"
SERVICE_RUNNER="$SERVICE_DIR/run-service.sh"

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "[bridge] error: python3 not found on PATH" >&2; exit 1; }

resolve_opencode() { if [ -n "${OPENCODE_BIN:-}" ]; then printf '%s' "$OPENCODE_BIN"; else command -v opencode 2>/dev/null || true; fi; }
truthy() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0;; *) return 1;; esac; }

# Populate the global ARGV array with the absolute command the bridge runs.
# Absolute paths so the service unit has no PATH ambiguity. (bash-3.2 safe.)
ARGV=()
build_argv() {
  ARGV=( "$PY" "$BRIDGE_PY" --host "$BRIDGE_HOST" --port "$BRIDGE_PORT" --model "$MODEL" \
         --cwd "$BRIDGE_CWD" --max-concurrency "$MAX_CONCURRENCY" --queue-wait "$QUEUE_WAIT" \
         --timeout "$TIMEOUT" )
  local opencode_bin; opencode_bin="$(resolve_opencode)"
  if [ -n "$opencode_bin" ];       then ARGV+=( --opencode-bin "$opencode_bin" ); fi
  if [ -n "$API_KEY" ];            then ARGV+=( --api-key "$API_KEY" ); fi
  if [ -n "$AGENT" ];              then ARGV+=( --agent "$AGENT" ); fi
  if [ -n "$VARIANT" ];            then ARGV+=( --variant "$VARIANT" ); fi
  if [ -n "${OPENCODE_BRIDGE_MODELS:-}" ]; then ARGV+=( --models "$OPENCODE_BRIDGE_MODELS" ); fi
  if truthy "$SHOW_TOOLS";         then ARGV+=( --show-tools ); fi
  if truthy "$SHOW_REASONING";     then ARGV+=( --show-reasoning ); fi
  if truthy "$FREE_ONLY"; then ARGV+=( --free-only ); else ARGV+=( --no-free-only ); fi
}

print_config() {
  local opencode_bin; opencode_bin="$(resolve_opencode)"
  echo "[bridge] config:"
  echo "  endpoint:       http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1"
  echo "  model:          ${MODEL}"
  echo "  cwd:            ${BRIDGE_CWD}"
  echo "  opencode:       ${opencode_bin:-not found}"
  echo "  free only:      $(truthy "$FREE_ONLY" && echo yes || echo 'no (paid models allowed)')"
  echo "  agent/variant:  ${AGENT:-(opencode default)} / ${VARIANT:-(default)}"
  echo "  max concurrency:${MAX_CONCURRENCY}"
  echo "  queue wait:     ${QUEUE_WAIT}s"
  echo "  request timeout:${TIMEOUT}s"
  echo "  api key:        $([ -n "$API_KEY" ] && echo required || echo not required)"
  echo "  trace in reply: tools=$(truthy "$SHOW_TOOLS" && echo on || echo off) reasoning=$(truthy "$SHOW_REASONING" && echo on || echo off)"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

shell_quote() {
  local quoted
  printf -v quoted '%q' "$1"
  printf '%s' "$quoted"
}

write_service_runner() {
  mkdir -p "$SERVICE_DIR"
  build_argv
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Auto-generated by %s install-service. Re-run install-service after config changes.\n' "$0"
    printf 'set -euo pipefail\n'
    # opencode itself must stay on PATH: it shells out to its own tools.
    local opencode_bin; opencode_bin="$(resolve_opencode)"
    printf 'export PATH=%s' "$(shell_quote "$(dirname "$PY")")"
    if [ -n "$opencode_bin" ]; then printf ':%s' "$(shell_quote "$(dirname "$opencode_bin")")"; fi
    printf ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"\n'
    printf 'exec'
    local arg
    for arg in "${ARGV[@]}"; do printf ' %s' "$(shell_quote "$arg")"; done
    printf '\n'
  } > "$SERVICE_RUNNER"
  chmod 755 "$SERVICE_RUNNER"
}

require_opencode() {
  command -v opencode >/dev/null 2>&1 || [ -n "${OPENCODE_BIN:-}" ] || {
    echo "[bridge] error: \`opencode\` not on PATH — install OpenCode (https://opencode.ai) or set OPENCODE_BIN" >&2
    exit 1; }
}

cmd_run() {
  require_opencode
  echo "[bridge] starting on ${BRIDGE_HOST}:${BRIDGE_PORT} (model=${MODEL})"
  print_config
  build_argv; exec "${ARGV[@]}"
}

cmd_test() {
  # bash-3.2: `"${auth[@]}"` on an EMPTY array aborts under `set -u`; the
  # ${auth[@]+"${auth[@]}"} guard is the portable idiom. Send the REAL key,
  # not a mask — a placeholder would just earn a 401.
  local -a auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer $API_KEY")
  echo "[bridge] GET /health"; curl -fsS ${auth[@]+"${auth[@]}"} "http://127.0.0.1:${BRIDGE_PORT}/health"; echo
  echo "[bridge] POST /v1/chat/completions (model=${MODEL})"
  curl -fsS --max-time "$((TIMEOUT + 30))" ${auth[@]+"${auth[@]}"} -H 'content-type: application/json' \
    "http://127.0.0.1:${BRIDGE_PORT}/v1/chat/completions" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: opencode bridge ok\"}],\"stream\":false}"; echo
}

cmd_stream() {
  local -a auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer $API_KEY")
  echo "[bridge] POST /v1/chat/completions (stream, model=${MODEL})"
  curl -fsSN --max-time "$((TIMEOUT + 30))" ${auth[@]+"${auth[@]}"} -H 'content-type: application/json' \
    "http://127.0.0.1:${BRIDGE_PORT}/v1/chat/completions" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 5, one number per line.\"}],\"stream\":true}"
}

cmd_image() {
  # End-to-end VISION test: base64 image_url content part -> bridge ->
  # opencode --file=<tmp>. This is exactly what Hermes sends for screenshots,
  # so if this passes, image attachments work in the app too.
  local img="${1:-}"
  [ -n "$img" ] || { echo "[bridge] usage: $0 image /path/to/image.(png|jpg|webp|gif)" >&2; exit 2; }
  [ -f "$img" ] || { echo "[bridge] error: file not found: $img" >&2; exit 2; }
  local -a auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer $API_KEY")
  echo "[bridge] POST /v1/chat/completions (vision, model=${MODEL}, image=$(basename -- "$img"))"
  "$PY" - "$img" <<PYEOF | curl -fsS ${auth[@]+"${auth[@]}"} --max-time "$((TIMEOUT + 30))" \
      -H 'content-type: application/json' -d @- \
      "http://127.0.0.1:${BRIDGE_PORT}/v1/chat/completions"; echo
import base64, json, mimetypes, sys
path = sys.argv[1]
mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
with open(path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
print(json.dumps({
    "model": "${MODEL}",
    "stream": False,
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "Describe this image in one short paragraph."},
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
    ]}],
}))
PYEOF
}

cmd_models() {
  local -a auth=(); [ -n "$API_KEY" ] && auth=(-H "Authorization: Bearer $API_KEY")
  curl -fsS ${auth[@]+"${auth[@]}"} "http://127.0.0.1:${BRIDGE_PORT}/v1/models" \
    | "$PY" -c 'import sys,json; [print(m["id"], "" if m.get("free") is None else ("(free)" if m["free"] else "(paid)")) for m in json.load(sys.stdin)["data"]]'
}

# ── service: macOS (launchd LaunchAgent) ──────────────────────────────────────
plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$LABEL"; }

install_launchd() {
  local plist; plist="$(plist_path)"; mkdir -p "$(dirname "$plist")"
  write_service_runner
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$LABEL"
    printf '  <key>ProgramArguments</key><array><string>%s</string></array>\n' "$(xml_escape "$SERVICE_RUNNER")"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '  <key>KeepAlive</key><true/>\n'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
    printf '  <key>EnvironmentVariables</key><dict>\n'
    printf '    <key>PATH</key><string>%s</string>\n' "$(xml_escape "$(dirname "$PY"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")"
    printf '  </dict>\n'
    printf '</dict></plist>\n'
  } > "$plist"
  # Modern launchctl (bootstrap/kickstart); `load -w` is deprecated on recent macOS.
  local domain="gui/$(id -u)" i
  launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  # bootout is async — wait until the label is really gone, or bootstrap no-ops.
  for i in $(seq 1 40); do launchctl print "$domain/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
  if ! launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
    launchctl load -w "$plist" >/dev/null 2>&1 || { echo "[bridge] error: launchd failed to load $plist" >&2; exit 1; }
  fi
  launchctl enable "$domain/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$LABEL" >/dev/null 2>&1 || true
  echo "[bridge] launchd service installed + started: $plist"
  echo "[bridge] runner: $SERVICE_RUNNER"
  echo "[bridge] logs: $LOG_FILE"
  print_config
}
uninstall_launchd() {
  local plist; plist="$(plist_path)"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
  rm -f "$plist" "$SERVICE_RUNNER" && echo "[bridge] launchd service removed"
}
status_launchd() { launchctl list 2>/dev/null | grep -F "$LABEL" || echo "[bridge] not loaded"; }

# ── service: Linux (systemd --user) ───────────────────────────────────────────
unit_path() { printf '%s/.config/systemd/user/%s.service' "$HOME" "$LABEL"; }

install_systemd() {
  command -v systemctl >/dev/null 2>&1 || { echo "[bridge] error: systemctl not found; run ./run-bridge.sh run under your own supervisor" >&2; exit 1; }
  local unit; unit="$(unit_path)"; mkdir -p "$(dirname "$unit")"
  write_service_runner
  cat > "$unit" <<UNIT
[Unit]
Description=OpenCode Bridge (Hermes custom endpoint)
After=network-online.target

[Service]
Type=simple
ExecStart=${SERVICE_RUNNER}
Restart=always
RestartSec=3
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "${LABEL}.service"
  loginctl enable-linger "$USER" >/dev/null 2>&1 || echo "[bridge] note: could not enable linger (service still runs while logged in)"
  echo "[bridge] systemd --user service installed + started: $unit"
  echo "[bridge] runner: $SERVICE_RUNNER"
  echo "[bridge] logs: $LOG_FILE  (also: journalctl --user -u ${LABEL})"
  print_config
}
uninstall_systemd() {
  systemctl --user disable --now "${LABEL}.service" >/dev/null 2>&1 || true
  rm -f "$(unit_path)" "$SERVICE_RUNNER" && systemctl --user daemon-reload && echo "[bridge] systemd service removed"
}
status_systemd() { systemctl --user status "${LABEL}.service" --no-pager 2>/dev/null || echo "[bridge] not installed"; }

os_kind() { case "$(uname -s)" in Darwin) echo mac;; Linux) echo linux;; *) echo other;; esac; }

cmd_install_service() {
  require_opencode
  case "$(os_kind)" in
    mac)   install_launchd ;;
    linux) install_systemd ;;
    *)     echo "[bridge] error: unsupported OS for auto-service; use ./run-bridge.sh run" >&2; exit 1 ;;
  esac
  # First boot takes a while (interpreter start + `opencode models` discovery,
  # sometimes >30s on a cold cache). Wait patiently and SAY so — a bare curl
  # "connection refused" here reads like the install broke when it didn't.
  local i up=0
  touch "$LOG_FILE"
  printf '[bridge] waiting for http://127.0.0.1:%s/health ' "$BRIDGE_PORT"
  for i in $(seq 1 240); do
    if curl -fsS "http://127.0.0.1:${BRIDGE_PORT}/health" >/dev/null 2>&1; then up=1; break; fi
    printf '.'; sleep 0.5
  done
  echo
  if [ "$up" -eq 1 ]; then
    cmd_test || echo "[bridge] (endpoint is up; the live completion above failed — retry or check: ./run-bridge.sh logs)"
  else
    echo "[bridge] warning: service not healthy after 120s. Last log lines:" >&2
    tail -n 15 "$LOG_FILE" >&2 || true
    echo "[bridge] (launchd keeps retrying; watch it with: ./run-bridge.sh logs)" >&2
    exit 1
  fi
}
cmd_uninstall_service() { case "$(os_kind)" in mac) uninstall_launchd;; linux) uninstall_systemd;; *) echo "nothing to do";; esac; }
cmd_service_status()   { case "$(os_kind)" in mac) status_launchd;;   linux) status_systemd;;   *) echo "n/a";; esac; }

case "${1:-run}" in
  run)                cmd_run ;;
  test)               cmd_test ;;
  stream)             cmd_stream ;;
  image)              shift; cmd_image "$@" ;;
  models)             cmd_models ;;
  selfcheck)          BRIDGE_SELFCHECK=1 exec "$PY" "$BRIDGE_PY" ;;
  install-service)    cmd_install_service ;;
  uninstall-service)  cmd_uninstall_service ;;
  service-status)     cmd_service_status ;;
  logs)               touch "$LOG_FILE"; tail -f "$LOG_FILE" ;;
  help|-h|--help)     awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) echo "[bridge] unknown command: ${1:-} (try: $0 help)" >&2; exit 1 ;;
esac
