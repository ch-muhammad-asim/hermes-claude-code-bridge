#!/usr/bin/env bash
# verify-perf.sh — confirm Hermes Desktop is launching with hardware GPU accel.
#
# Run after starting Hermes Desktop (via the launcher icon or `gtk-launch hermes-desktop`).
# Reports: process state, GPU/software-render markers from the log, Mesa/NVIDIA hits.
#
set -u

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/hermes-desktop.log"

print_header() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✘\033[0m %s\n' "$*"; }
neutral() { printf '  • %s\n' "$*"; }

print_header "Process state"
pids=$(pgrep -af '/Hermes\b' | grep -v '\-\-type=zygote\|\-\-type=utility\|\-\-type=gpu\|\-\-type=renderer\|\-\-type=broker' || true)
if [ -z "$pids" ]; then
  bad "Hermes Desktop is NOT running (launch it first: gtk-launch hermes-desktop)"
  exit 1
fi
echo "$pids" | head -3 | while read -r line; do neutral "$line"; done

print_header "Wrapper invocation"
last_launch=$(grep "launching packaged Hermes Desktop" "$LOG" | tail -1)
if [ -n "$last_launch" ]; then
  neutral "$last_launch"
  if echo "$last_launch" | grep -q "disable-gpu"; then
    bad "Wrapper launched with --disable-gpu (software rendering forced)"
  else
    ok "Wrapper did NOT pass --disable-gpu"
  fi
  if echo "$last_launch" | grep -q "enable-gpu-rasterization"; then
    ok "Wrapper passed --enable-gpu-rasterization"
  fi
else
  bad "No 'launching packaged Hermes Desktop' line in $LOG"
fi

print_header "App self-detection"
last_remote=$(grep "remote display detected" "$LOG" | tail -1)
if [ -z "$last_remote" ]; then
  ok "App did NOT detect a remote display (GPU stays ON)"
else
  reason=$(echo "$last_remote" | sed -n 's/.*remote display detected (\([^)]*\)).*/\1/p')
  bad "App disabled GPU. Reason: $reason"
  case "$reason" in
    "override (HERMES_DESKTOP_DISABLE_GPU)")
      neutral "→ Your env still has HERMES_DESKTOP_DISABLE_GPU=1. The new wrapper sets =0. Restart Hermes."
      ;;
    ssh-session)
      neutral "→ You launched from an SSH session. Open Hermes from the desktop menu instead."
      ;;
    x11-forwarding*)
      neutral "→ DISPLAY is X11-forwarded. Run Hermes locally (DISPLAY=:0 or :1)."
      ;;
  esac
fi

print_header "Recent log tail (last 12 lines)"
tail -12 "$LOG" | sed 's/^/  /'

print_header "Summary"
if pgrep -af '/Hermes.*--type=gpu' >/dev/null 2>&1; then
  ok "GPU process is running (Chromium spawned a --type=gpu child)"
else
  bad "No GPU child process found — check chrome://gpu in the app"
fi
