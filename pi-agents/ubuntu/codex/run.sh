#!/usr/bin/env bash
#
# run.sh — codex on Ubuntu: run the pi coding agent in your terminal on the OpenAI Codex CLI.
#
#   pi (its own tools, your cwd) ──▶ pure-LLM codex bridge :18288 ──▶ `codex exec --json`
#                                    tool calls emulated over text by the shared pi provider
#
# Codex apps and MCP servers you have already connected (Atlassian, Slack, documents, …) come
# through automatically — see README.md, "Codex apps and MCP servers".
#
# Usage (from this folder):
#   ./run.sh upstream          # foreground pure-LLM codex bridge on :18288 (leave running)
#   ./run.sh pi [args…]        # start pi with this provider, in the CURRENT directory
#   ./run.sh test              # headless pi run: the model must call pi's bash tool itself
#   ./run.sh models            # models the bridge advertises
#   ./run.sh install-service   # bridge as an enabled systemd --user service + linger
#   ./run.sh uninstall-service | service-status | restart | logs | journal
#
# systemd unit: pi-cli-codex.service (--user)
#
# Config (env or .env next to this script): UPSTREAM_PORT 18288, PI_CLI_MODEL gpt-5.6-sol,
#   CODEX_BIN, CODEX_HOME, CODEX_BRIDGE_SANDBOX (read-only), CODEX_BRIDGE_CWD, CODEX_BRIDGE_TIMEOUT
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
COMMON="$HERE/../common"
BRIDGE="$HERE/codex_bridge.py"          # symlink into ../../macos/codex/ — the bridge is platform-neutral
UPSTREAM_PORT="${UPSTREAM_PORT:-18288}"
MODEL="${PI_CLI_MODEL:-gpt-5.6-sol}"
# Plain systemd unit stem (the reverse-DNS label in macos/ is a launchd convention).
LABEL="pi-cli-codex"
LOG_FILE="${PI_CLI_LOG:-$HOME/.pi-cli-codex.log}"
SERVICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-cli-codex"
PI_BIN="${PI_BIN:-$(command -v pi || echo "$HOME/.local/bin/pi")}"

[ "$(uname -s)" = "Linux" ] || { echo "[codex] error: this is the Ubuntu/Linux tree — on macOS use ../../macos/codex/" >&2; exit 1; }

shell_quote() { local q; printf -v q '%q' "$1"; printf '%s' "$q"; }
require() {
  command -v python3 >/dev/null 2>&1 || { echo "[codex] error: python3 not on PATH — sudo apt install -y python3" >&2; exit 1; }
  command -v codex >/dev/null 2>&1 || [ -x "${CODEX_BIN:-}" ] \
    || { echo "[codex] error: codex not on PATH — npm i -g @openai/codex && codex login" >&2; exit 1; }
  [ -f "$BRIDGE" ] || { echo "[codex] error: $BRIDGE missing (broken symlink into ../../macos/codex/?)" >&2; exit 1; }
}

cmd_upstream() {
  require
  echo "[codex] pure-LLM codex bridge on :${UPSTREAM_PORT} — codex's own shell stays out of the way; pi runs the tools"
  CODEX_BRIDGE_PORT="$UPSTREAM_PORT" CODEX_BRIDGE_MODEL="$MODEL" \
  CODEX_BRIDGE_CWD="${CODEX_BRIDGE_CWD:-$SERVICE_DIR/sandbox-root}" \
  CODEX_BRIDGE_SANDBOX="${CODEX_BRIDGE_SANDBOX:-read-only}" \
  CODEX_BRIDGE_TIMEOUT="${CODEX_BRIDGE_TIMEOUT:-600}" \
  CODEX_BRIDGE_MAX_CONCURRENCY="${CODEX_BRIDGE_MAX_CONCURRENCY:-2}" \
    exec python3 "$BRIDGE"
}

# After install.sh the extension is already in ~/.pi/agent/settings.json — don't load it twice.
ext_args() {
  grep -qsF "$HERE/extensions/codex-cli" "$HOME/.pi/agent/settings.json" 2>/dev/null || printf -- '-e\n%s\n' "$HERE/extensions/codex-cli"
  case "${PI_CLI_GUARDRAILS:-0}" in 1|true|yes|on) printf -- '-e\n%s\n' "$COMMON/extensions/guardrails" ;; esac
}

cmd_pi() {
  [ -x "$PI_BIN" ] || { echo "[codex] error: pi not found — npm install -g @earendil-works/pi-coding-agent" >&2; exit 1; }
  curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 || \
    echo "[codex] note: bridge :${UPSTREAM_PORT} not answering — run: $0 install-service   (or $0 upstream)"
  local -a ext=(); while IFS= read -r line; do ext+=("$line"); done < <(ext_args)
  exec "$PI_BIN" ${ext[@]+"${ext[@]}"} --provider codex-cli --model "$MODEL" "$@"
}

cmd_test() {
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-codex-cli-test.XXXX")"
  local -a ext=(); while IFS= read -r line; do ext+=("$line"); done < <(ext_args)
  echo "[codex] headless pi in $dir — expect the model to CALL pi's bash tool, not describe it:"
  echo "[codex] note: on pi 0.86.x headless -p sends NO tools to a text-emulated provider — see README."
  ( cd "$dir" && printf '%s' "Use your bash tool to run: pwd && echo pi-codex-cli-ok. Then report the output." \
    | PI_APPROVAL_NONINTERACTIVE="${PI_APPROVAL_NONINTERACTIVE:-allow}" \
      "$PI_BIN" -p --no-session ${ext[@]+"${ext[@]}"} --provider codex-cli --model "$MODEL" )
  echo; rmdir "$dir" 2>/dev/null || true
}

cmd_models() { curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/v1/models" | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin)["data"]]'; }

write_runner() {
  mkdir -p "$SERVICE_DIR" "${CODEX_BRIDGE_CWD:-$SERVICE_DIR/sandbox-root}"
  chmod 700 "${CODEX_BRIDGE_CWD:-$SERVICE_DIR/sandbox-root}" 2>/dev/null || true
  local py npm_bin; py="$(command -v python3)"; npm_bin="$( (npm prefix -g 2>/dev/null || true) )"
  [ -n "$npm_bin" ] && npm_bin="$npm_bin/bin"
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service. Do not edit — re-run install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=%s:%s:%s/.local/bin:/usr/local/bin:/usr/bin:/bin\n' \
      "$(shell_quote "$(dirname "$py")")" "$(shell_quote "${npm_bin:-/usr/local/bin}")" "$(shell_quote "$HOME")"
    printf 'export HOME=%s\n' "$(shell_quote "$HOME")"
    for v in UPSTREAM_PORT PI_CLI_MODEL CODEX_BIN CODEX_HOME CODEX_BRIDGE_CWD CODEX_BRIDGE_SANDBOX \
             CODEX_BRIDGE_TIMEOUT CODEX_BRIDGE_MAX_CONCURRENCY CODEX_BRIDGE_BYPASS_HOOK_TRUST; do
      [ -n "${!v:-}" ] && printf 'export %s=%s\n' "$v" "$(shell_quote "${!v}")"
    done
    printf 'exec %s upstream\n' "$(shell_quote "$HERE/run.sh")"
  } > "$SERVICE_DIR/run-upstream.sh"
  chmod 755 "$SERVICE_DIR/run-upstream.sh"
}

listener_pid() {
  local pid
  pid="$(ss -ltnpH "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  [ -n "$pid" ] || pid="$(lsof -tnP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  printf '%s' "$pid"
}

cmd_install_service() {
  require; write_runner
  # a leftover foreground bridge on the port would make the service crash-loop
  local pid; pid="$(listener_pid "$UPSTREAM_PORT")"
  if [ -n "$pid" ] && ! ps -o args= -p "$pid" 2>/dev/null | grep -q "pi-cli-codex/run-upstream"; then
    echo "[codex] port $UPSTREAM_PORT held by pid $pid — stopping it"; kill "$pid" 2>/dev/null || true; sleep 1
  fi
  local unit="$HOME/.config/systemd/user/$LABEL.service"; mkdir -p "$(dirname "$unit")"
  {
    printf '[Unit]\nDescription=codex: pure-LLM Codex CLI bridge for terminal pi (:%s)\n' "$UPSTREAM_PORT"
    printf 'Documentation=file://%s/README.md\n' "$HERE"
    printf 'Wants=network-online.target\nAfter=network-online.target\n'
    printf 'StartLimitIntervalSec=300\nStartLimitBurst=10\n\n'
    printf '[Service]\nType=simple\nExecStart=%s\n' "$SERVICE_DIR/run-upstream.sh"
    printf 'WorkingDirectory=%s\n' "$HOME"
    printf 'Restart=always\nRestartSec=3\nTimeoutStopSec=20\nKillMode=mixed\n'
    printf 'StandardOutput=append:%s\nStandardError=append:%s\n' "$LOG_FILE" "$LOG_FILE"
    printf 'SyslogIdentifier=%s\nNoNewPrivileges=true\n\n' "$LABEL"
    printf '[Install]\nWantedBy=default.target\n'
  } > "$unit"
  systemctl --user daemon-reload
  systemctl --user reset-failed "$LABEL.service" >/dev/null 2>&1 || true
  systemctl --user enable "$LABEL.service" >/dev/null
  systemctl --user restart "$LABEL.service"
  # Without linger a --user service stops when your last login session ends (ssh logout, reboot).
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != "yes" ]; then
    loginctl enable-linger "$USER" >/dev/null 2>&1 \
      || echo "[codex] warning: could not enable linger — run: sudo loginctl enable-linger $USER" >&2
  fi
  echo "[codex] systemd --user: $LABEL.service → $unit (log $LOG_FILE)"
  printf '[codex] waiting for http://127.0.0.1:%s/health ' "$UPSTREAM_PORT"
  local i; for i in $(seq 1 120); do curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 && { echo; return 0; }; printf '.'; sleep 0.5; done
  echo; echo "[codex] warning: bridge not healthy yet — check: $0 logs" >&2; return 1
}
cmd_uninstall_service() {
  systemctl --user disable --now "$LABEL.service" >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/$LABEL.service"; systemctl --user daemon-reload
  rm -f "$SERVICE_DIR/run-upstream.sh"; echo "[codex] service removed"
}
cmd_status() {
  systemctl --user status "$LABEL.service" --no-pager 2>/dev/null || echo "[codex] not installed"
  echo
  printf '[codex] enabled at boot: %s   linger: %s   /health :%s → %s\n' \
    "$(systemctl --user is-enabled "$LABEL.service" 2>/dev/null || echo no)" \
    "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)" \
    "$UPSTREAM_PORT" "$(curl -fsS -m 3 "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 && echo ok || echo DOWN)"
}

case "${1:-pi}" in
  upstream)          cmd_upstream ;;
  pi)                shift; cmd_pi "$@" ;;
  test)              cmd_test ;;
  models)            cmd_models ;;
  install-service)   cmd_install_service ;;
  uninstall-service) cmd_uninstall_service ;;
  service-status)    cmd_status ;;
  restart)           systemctl --user restart "$LABEL.service"; cmd_status ;;
  logs)              touch "$LOG_FILE"; tail -f "$LOG_FILE" ;;
  journal)           journalctl --user -u "$LABEL.service" -n 200 -f ;;
  help|-h|--help)    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) echo "[codex] unknown command: $1 (try: $0 help)" >&2; exit 1 ;;
esac
