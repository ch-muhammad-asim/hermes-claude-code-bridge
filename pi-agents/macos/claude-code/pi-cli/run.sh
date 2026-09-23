#!/usr/bin/env bash
#
# run.sh — pi-cli: run the pi coding agent in your terminal with Claude Code as the model.
#
#   pi (native tools, no guardrails) ──▶ Claude Code NATIVE bridge :18187 ──▶ one warm `claude` per chat
#                                        pi's tools = real functions (MCP shim) · built-ins OFF · ALL connectors ON
#
# Usage (from this folder):
#   ./run.sh upstream          # foreground Claude Code bridge on :18187 (leave running)
#   ./run.sh pi [args…]        # start pi with this provider, in the CURRENT directory
#   ./run.sh test              # headless pi run: a shell command + a connector call
#   ./run.sh models            # models the bridge advertises
#   ./run.sh install-service   # bridge as an auto-start user service (launchd / systemd --user)
#   ./run.sh uninstall-service | service-status | logs
#
# Config (env or .env next to this script): UPSTREAM_PORT 18187, PI_CLI_MODEL claude-opus-5,
#   CLAUDE_CODE_EFFORT medium, CLAUDE_CODE_MAX_BUDGET_USD, CLAUDE_BIN
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
COMMON="$HERE/../../common"
NATIVE_BRIDGE="$HERE/../native/claude_native_bridge.py"
UPSTREAM_PORT="${UPSTREAM_PORT:-18187}"
MODEL="${PI_CLI_MODEL:-claude-opus-5}"
MODELS="${CLAUDE_CODE_BRIDGE_MODELS:-claude-opus-5,claude-opus-5-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8,claude-sonnet-5,claude-sonnet-4-6,claude-haiku-4-5}"
LABEL="com.hermes.claude-code-pi-cli"
LOG_FILE="${PI_CLI_LOG:-$HOME/.pi-cli-claude-code.log}"
SERVICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-cli-claude-code"
# Claude's local tools are pi's job; everything else Claude has (every claude.ai connector) stays on.
CLAUDE_BUILTINS="Bash,Edit,Write,MultiEdit,NotebookEdit,Read,Glob,Grep,LS,Task,TodoWrite,TodoRead,AskUserQuestion,Skill,SlashCommand,KillShell,BashOutput,EnterPlanMode,ExitPlanMode,PowerShell,CronCreate,CronDelete,CronList,Monitor,RemoteTrigger,SendMessage,ListAgents,TaskOutput,TaskStop,EnterWorktree,ExitWorktree,PushNotification"
PI_BIN="${PI_BIN:-$(command -v pi || echo "$HOME/.local/bin/pi")}"

shell_quote() { local q; printf -v q '%q' "$1"; printf '%s' "$q"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
os_kind() { case "$(uname -s)" in Darwin) echo mac;; Linux) echo linux;; *) echo other;; esac; }
require() {
  command -v claude >/dev/null 2>&1 || [ -n "${CLAUDE_BIN:-}" ] || { echo "[pi-cli] error: claude not on PATH" >&2; exit 1; }
  [ -f "$NATIVE_BRIDGE" ] || { echo "[pi-cli] error: $NATIVE_BRIDGE missing" >&2; exit 1; }
}

# Claude's WebSearch/WebFetch stay ON — pi has no web tool of its own, so denying them would
# leave the agent with no internet access at all. Set PI_CLAUDE_WEB=0 for an offline agent.
claude_deny() {
  if [ "${PI_CLAUDE_WEB:-1}" = "0" ]; then printf '%s,%s' "$CLAUDE_BUILTINS" "WebSearch,WebFetch"; else printf '%s' "$CLAUDE_BUILTINS"; fi
}

cmd_upstream() {
  require
  # Started from inside a Claude Code / Agent SDK session? Those variables make the spawned `claude`
  # look like a third-party app ("Third-party apps now draw from extra usage"). Drop them.
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_AGENT_SDK_VERSION CLAUDE_CODE_OAUTH_SCOPES ANTHROPIC_BASE_URL CLAUDE_CODE_DESKTOP_APP_VERSION 2>/dev/null || true
  echo "[pi-cli] Claude Code NATIVE bridge on :${UPSTREAM_PORT} — pi tools as real functions, built-ins off, all connectors on"
  BRIDGE_PORT="$UPSTREAM_PORT" CLAUDE_CODE_BRIDGE_MODEL="$MODEL" CLAUDE_CODE_BRIDGE_MODELS="$MODELS" \
  CLAUDE_CODE_EFFORT="${CLAUDE_CODE_EFFORT:-medium}" CLAUDE_CODE_ALLOWED_TOOLS="*" \
  CLAUDE_CODE_DISALLOWED_TOOLS="$(claude_deny)" CLAUDE_CODE_BRIDGE_TIMEOUT="${CLAUDE_CODE_BRIDGE_TIMEOUT:-600}" \
    exec python3 "$HERE/../native/claude_native_bridge.py"
}

# After install.sh the extension is already in ~/.pi/agent/settings.json — don't load it twice.
ext_args() { grep -qsF "$HERE/extensions/claude-code" "$HOME/.pi/agent/settings.json" 2>/dev/null && return 0; printf -- '-e\n%s\n' "$HERE/extensions/claude-code"; }

cmd_pi() {
  [ -x "$PI_BIN" ] || { echo "[pi-cli] error: pi not found — npm install -g @earendil-works/pi-coding-agent" >&2; exit 1; }
  curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 || \
    echo "[pi-cli] note: bridge :${UPSTREAM_PORT} not answering — run: $0 upstream   (or $0 install-service)"
  local -a ext=(); while IFS= read -r line; do ext+=("$line"); done < <(ext_args)
  exec "$PI_BIN" ${ext[@]+"${ext[@]}"} --provider claude-code --model "$MODEL" "$@"
}

cmd_test() {
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-cli-test.XXXX")"
  local -a ext=(); while IFS= read -r line; do ext+=("$line"); done < <(ext_args)
  echo "[pi-cli] headless pi in $dir — expect a pi bash call AND a connector answer:"
  ( cd "$dir" && printf '%s' "Run pwd with your bash tool. Then, using your Atlassian connector, tell me the Atlassian site URL you can access (or say NO CONNECTOR)." \
    | "$PI_BIN" -p --no-session ${ext[@]+"${ext[@]}"} --provider claude-code --model "$MODEL" )
  echo; rmdir "$dir" 2>/dev/null || true
}

cmd_models() { curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/v1/models" | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin)["data"]]'; }

write_runner() {
  mkdir -p "$SERVICE_DIR"
  {
    printf '#!/usr/bin/env bash\n# Auto-generated by %s install-service.\nset -euo pipefail\n' "$0"
    printf 'export PATH=/opt/homebrew/bin:/usr/local/bin:%s/.local/bin:/usr/bin:/bin:"$PATH"\n' "$(shell_quote "$HOME")"
    for v in UPSTREAM_PORT PI_CLI_MODEL CLAUDE_CODE_BRIDGE_MODELS CLAUDE_CODE_EFFORT CLAUDE_CODE_MAX_BUDGET_USD CLAUDE_CODE_BRIDGE_TIMEOUT CLAUDE_BIN; do
      [ -n "${!v:-}" ] && printf 'export %s=%s\n' "$v" "$(shell_quote "${!v}")"
    done
    printf 'exec %s upstream\n' "$(shell_quote "$HERE/run.sh")"
  } > "$SERVICE_DIR/run-upstream.sh"
  chmod 755 "$SERVICE_DIR/run-upstream.sh"
}
cmd_install_service() {
  require; write_runner
  # a leftover foreground bridge on the port would make the service crash-loop
  local pid; pid="$(lsof -tnP -iTCP:"$UPSTREAM_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ] && ! ps -o command= -p "$pid" | grep -q "pi-cli-claude-code/run-upstream"; then
    echo "[pi-cli] port $UPSTREAM_PORT held by pid $pid — stopping it"; kill "$pid" 2>/dev/null || true; sleep 1; fi
  case "$(os_kind)" in
    mac)
      local plist="$HOME/Library/LaunchAgents/$LABEL.plist" domain="gui/$(id -u)" i
      mkdir -p "$(dirname "$plist")"
      {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
        printf '  <key>Label</key><string>%s</string>\n  <key>ProgramArguments</key><array><string>%s</string></array>\n' "$LABEL" "$(xml_escape "$SERVICE_DIR/run-upstream.sh")"
        printf '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n'
        printf '  <key>StandardOutPath</key><string>%s</string>\n  <key>StandardErrorPath</key><string>%s</string>\n</dict></plist>\n' "$(xml_escape "$LOG_FILE")" "$(xml_escape "$LOG_FILE")"
      } > "$plist"
      launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
      for i in $(seq 1 40); do launchctl print "$domain/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
      launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist"
      launchctl enable "$domain/$LABEL" >/dev/null 2>&1 || true
      echo "[pi-cli] launchd: $LABEL → $plist (log $LOG_FILE)" ;;
    linux)
      local unit="$HOME/.config/systemd/user/$LABEL.service"; mkdir -p "$(dirname "$unit")"
      printf '[Unit]\nDescription=pi-cli: Claude Code bridge for pi\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=%s\nRestart=always\nRestartSec=3\nStandardOutput=append:%s\nStandardError=append:%s\n\n[Install]\nWantedBy=default.target\n' "$SERVICE_DIR/run-upstream.sh" "$LOG_FILE" "$LOG_FILE" > "$unit"
      systemctl --user daemon-reload; systemctl --user enable --now "$LABEL.service"; loginctl enable-linger "$USER" >/dev/null 2>&1 || true
      echo "[pi-cli] systemd: $LABEL → $unit" ;;
    *) echo "[pi-cli] unsupported OS for a service; use: $0 upstream" >&2; exit 1 ;;
  esac
  printf '[pi-cli] waiting for http://127.0.0.1:%s/health ' "$UPSTREAM_PORT"
  local i; for i in $(seq 1 120); do curl -fsS "http://127.0.0.1:${UPSTREAM_PORT}/health" >/dev/null 2>&1 && { echo; return 0; }; printf '.'; sleep 0.5; done
  echo; echo "[pi-cli] warning: bridge not healthy yet — check: $0 logs" >&2; return 1
}
cmd_uninstall_service() {
  case "$(os_kind)" in
    mac)   launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true; rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" ;;
    linux) systemctl --user disable --now "$LABEL.service" >/dev/null 2>&1 || true; rm -f "$HOME/.config/systemd/user/$LABEL.service"; systemctl --user daemon-reload ;;
  esac
  rm -f "$SERVICE_DIR/run-upstream.sh"; echo "[pi-cli] service removed"
}
cmd_status() { case "$(os_kind)" in mac) launchctl list 2>/dev/null | grep -F "$LABEL" || echo "[pi-cli] not loaded";; linux) systemctl --user status "$LABEL.service" --no-pager 2>/dev/null || echo "[pi-cli] not installed";; esac; }

case "${1:-pi}" in
  upstream)          cmd_upstream ;;
  pi)                shift; cmd_pi "$@" ;;
  test)              cmd_test ;;
  models)            cmd_models ;;
  install-service)   cmd_install_service ;;
  uninstall-service) cmd_uninstall_service ;;
  service-status)    cmd_status ;;
  logs)              touch "$LOG_FILE"; tail -f "$LOG_FILE" ;;
  help|-h|--help)    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) echo "[pi-cli] unknown command: $1 (try: $0 help)" >&2; exit 1 ;;
esac
