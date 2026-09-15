#!/usr/bin/env bash
#
# install.sh — Register "Hermes Desktop" as a proper Ubuntu/Debian application.
#
# Installs the official Hermes icon and a .desktop launcher so Hermes shows up
# in the Applications grid (searchable / pinnable to the dock) instead of being
# started from a terminal with `hermes desktop`.
#
# Designed to work out-of-the-box on every recent Ubuntu (22.04/24.04+) and
# Debian (11/12+) desktop, on both Wayland and X11, with or without optional
# tooling (ImageMagick / xdg-utils) installed.
#
# Idempotent: re-run any time (e.g. after a Hermes update) to refresh the entry.
#
#   Usage:   ./install.sh               # install / refresh
#            ./install.sh --reset-state # also reset stale Electron UI state
#            ./install.sh --uninstall
#
# Overridable via env:  HERMES_BIN, HERMES_UNPACKED, HERMES_APP_BIN, ICON_SRC, ICON_URL, APP_NAME
#
set -euo pipefail

# --- config ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_ID="hermes-desktop"                      # desktop-file / icon basename
APP_NAME="${APP_NAME:-Hermes Desktop}"       # human-readable menu name
HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"

# XDG base dirs (respect overrides, fall back to spec defaults)
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
ICON_BASE="$DATA_HOME/icons/hicolor"
DESKTOP_FILE="$APPS_DIR/$APP_ID.desktop"

# Electron's SUID sandbox helper. `hermes desktop` expects this to be
# root:root mode 4755; otherwise it tries to `sudo chown/chmod` it on every
# launch — which silently fails from a GUI menu (no terminal for the sudo
# password), so the app never opens. We configure it once here, at install
# time, while a terminal is available. Override with HERMES_UNPACKED if your
# install lives elsewhere.
HERMES_UNPACKED="${HERMES_UNPACKED:-$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked}"
CHROME_SANDBOX="$HERMES_UNPACKED/chrome-sandbox"
HERMES_APP_BIN="${HERMES_APP_BIN:-$HERMES_UNPACKED/Hermes}"
DESKTOP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Hermes"

# The .desktop launches a wrapper (not `hermes desktop` directly). The wrapper
# re-applies Electron's setuid sandbox bit if a Hermes repackage stripped it,
# using pkexec (a graphical password dialog) — only when actually needed — then
# launches the app. No standing sudoers/NOPASSWD rule is installed.
WRAPPER="$DATA_HOME/hermes-desktop/launch-hermes-desktop.sh"

# Icon resolution order:
#   1) $ICON_SRC if set/exists
#   2) pre-built 512px icon shipped next to this script
#   3) the source icon shipped next to this script (any size)
#   4) downloaded fresh from $ICON_URL (official site icon)
ICON_URL="${ICON_URL:-https://raw.githubusercontent.com/ch-muhammad-asim/hermes-claude-code-bridge/main/ubuntu-desktop/hermes-icon-512.png}"
ICON_BUILT="$SCRIPT_DIR/hermes-icon-512.png"
ICON_SOURCE="$SCRIPT_DIR/hermes-icon-source.png"

ICON_SIZES=(512 256 128 64 48 32)

# --- helpers ---------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Resize $1 -> $2 at WxW pixels. Falls back to a plain copy if no ImageMagick.
resize_icon() {
  local src="$1" dst="$2" w="$3"
  if have magick; then
    magick "$src" -filter Lanczos -resize "${w}x${w}" "$dst" 2>/dev/null && return 0
  fi
  if have convert; then
    convert "$src" -filter Lanczos -resize "${w}x${w}" "$dst" 2>/dev/null && return 0
  fi
  cp -f "$src" "$dst"   # last resort: unscaled copy (still works, just not size-tuned)
}

# Apply root:root 4755 to chrome-sandbox right now (install-time, terminal
# available). Best-effort; callers warn rather than die on failure.
_apply_sandbox_perms() {
  if [ "$(id -u)" = "0" ]; then
    chown root:root "$CHROME_SANDBOX" && chmod 4755 "$CHROME_SANDBOX"
  else
    sudo chown root:root "$CHROME_SANDBOX" && sudo chmod 4755 "$CHROME_SANDBOX"
  fi
}

_sandbox_ok() {
  [ "$(stat -c '%u' "$CHROME_SANDBOX" 2>/dev/null)" = "0" ] \
    && [ "$(stat -c '%a' "$CHROME_SANDBOX" 2>/dev/null)" = "4755" ]
}

reset_desktop_state() {
  [ -d "$DESKTOP_CONFIG_DIR" ] || return 0

  local stamp backup_dir item moved=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$DESKTOP_CONFIG_DIR/reset-backup-$stamp"

  for item in \
    "Local Storage" \
    "Session Storage" \
    "IndexedDB" \
    "Code Cache" \
    "Cache" \
    "GPUCache" \
    "DawnCache" \
    "blob_storage" \
    "Shared Dictionary"; do
    if [ -e "$DESKTOP_CONFIG_DIR/$item" ]; then
      mkdir -p "$backup_dir"
      mv "$DESKTOP_CONFIG_DIR/$item" "$backup_dir/"
      moved=1
    fi
  done

  if [ "$moved" = "1" ]; then
    log "Reset Hermes Desktop renderer state; backup -> $backup_dir"
  else
    rmdir "$backup_dir" 2>/dev/null || true
    log "No stale Hermes Desktop renderer state found to reset."
  fi
}

# Write the wrapper the .desktop launches. If the setuid bit is missing it
# re-applies it via pkexec (a graphical password dialog, shown only when
# needed), then launches the packaged app directly. That avoids re-running the
# CLI desktop/update path on every GUI start. Logs to a file so GUI failures are
# debuggable. No terminal and no standing privilege rule required.
install_wrapper() {
  mkdir -p "$(dirname "$WRAPPER")"
  cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# Auto-generated by hermes-agent/ubuntu-desktop/install.sh. Launched by the
# Hermes Desktop .desktop entry. Re-applies Electron's SUID sandbox bit (via a
# graphical pkexec prompt) if a Hermes update stripped it, then launches the
# app — no terminal needed.
set -u
SANDBOX="$CHROME_SANDBOX"
APP_BIN="$HERMES_APP_BIN"
HERMES_BIN="$HERMES_BIN"
LOG="\${XDG_STATE_HOME:-\$HOME/.local/state}/hermes-desktop.log"
# --- Performance defaults (override per-launch via env) -------------------
# Self-update is OFF by default for fast startup. To pull the latest fork
# build, set HERMES_DESKTOP_DISABLE_SELF_UPDATE=0 (or unset it) for one launch.
export HERMES_DESKTOP_DISABLE_SELF_UPDATE="\${HERMES_DESKTOP_DISABLE_SELF_UPDATE:-1}"
# GPU acceleration is ON by default (was off in older installs). To force the
# software renderer for debugging, set HERMES_DESKTOP_DISABLE_GPU=1.
export HERMES_DESKTOP_DISABLE_GPU="\${HERMES_DESKTOP_DISABLE_GPU:-0}"
# Electron / Chromium perf flags applied to the packaged app. Override the
# whole list with HERMES_DESKTOP_ELECTRON_FLAGS="--flag-a --flag-b"; leave
# empty to launch with no extra flags.
# Default flag set tuned for Electron 28+ on native Linux (X11/Wayland), Intel
# Iris Xe + NVIDIA (PRIME on-demand). Verified against a workflow audit of
# Chromium/Electron docs:
#   --enable-zero-copy                       skip an intermediate memcpy for raster tiles
#   --ignore-gpu-blocklist                   force GPU on hardware the blocklist disables
#   --enable-gpu-rasterization               raster on the GPU instead of CPU
#   --enable-features=VaapiVideoDecoder      hw video decode (modern flag — VaapiVideoDecodeLinuxGL is legacy)
#                    ,VaapiVideoEncoder
#                    ,VaapiIgnoreDriverChecks  accept iHD on Ubuntu 24.04 (Iris Xe TigerLake)
#                    ,CanvasOopRasterization   GPU-rasterize 2D canvas (chat scroller / streaming text)
#   --disable-features=CalculateNativeWinOcclusion
#                                            FIX for "agent stops when window covered" — Chromium 120+
#                                            marks occluded windows hidden even with renderer-bg disabled
#                                            (see anthropics/claude-code#53475)
# Skipped on purpose: UseOzonePlatform (default on Electron 28+; redundant),
#   Vulkan / use-angle=vulkan (broken on hybrid Intel+NVIDIA; basecamp/omarchy#4901),
#   --use-gl=desktop (Electron picks the right path automatically).
# JS heap: 4096MB main process — set higher via HERMES_DESKTOP_MAX_OLD_SPACE for huge agents.
DEFAULT_PERF_FLAGS="--enable-zero-copy --ignore-gpu-blocklist --enable-gpu-rasterization --enable-features=VaapiVideoDecoder,VaapiVideoEncoder,VaapiIgnoreDriverChecks,CanvasOopRasterization --disable-features=CalculateNativeWinOcclusion --js-flags=--max-old-space-size=\${HERMES_DESKTOP_MAX_OLD_SPACE:-4096}"
PERF_FLAGS="\${HERMES_DESKTOP_ELECTRON_FLAGS-\$DEFAULT_PERF_FLAGS}"
# Disable GPU entirely if requested (perf flags become useless then).
if [ "\$HERMES_DESKTOP_DISABLE_GPU" = "1" ]; then
  PERF_FLAGS="--disable-gpu --disable-gpu-compositing"
fi
# Cache the sandbox stat() result once — was called up to 4× on the hot path.
SANDBOX_STAT=""
if [ -e "\$SANDBOX" ]; then
  SANDBOX_STAT="\$(stat -c '%u:%a' "\$SANDBOX" 2>/dev/null)"
fi
ok() { [ "\$SANDBOX_STAT" = "0:4755" ]; }
mkdir -p "\$(dirname "\$LOG")" 2>/dev/null || true
# Happy path stays silent (saves a synchronous disk write); only log when the
# sandbox bit needs repair or the app is missing — those are debuggable events.
if [ -e "\$SANDBOX" ] && ! ok; then
  echo "[\$(date -Is)] sandbox bit missing; repairing via pkexec" >>"\$LOG"
  if command -v pkexec >/dev/null 2>&1; then
    # Single elevated shell does both ops, so the user sees at most one dialog.
    pkexec sh -c "chown root:root '\$SANDBOX' && chmod 4755 '\$SANDBOX'" 2>>"\$LOG" || \
      echo "[\$(date -Is)] pkexec repair failed or was cancelled" >>"\$LOG"
    # Refresh the cache after a successful pkexec so the subsequent check sees the new mode.
    SANDBOX_STAT="\$(stat -c '%u:%a' "\$SANDBOX" 2>/dev/null)"
  else
    echo "[\$(date -Is)] pkexec not found; run ./install.sh from a terminal to repair" >>"\$LOG"
  fi
fi
if [ -x "\$APP_BIN" ]; then
  # shellcheck disable=SC2086  # word-splitting PERF_FLAGS is intentional
  echo "[\$(date -Is)] launching packaged Hermes Desktop (perf_flags=\$PERF_FLAGS)" >>"\$LOG"
  if ! ok; then
    echo "[\$(date -Is)] sandbox unavailable; launching with --no-sandbox (perf_flags=\$PERF_FLAGS)" >>"\$LOG"
    exec "\$APP_BIN" --no-sandbox \$PERF_FLAGS "\$@" >>"\$LOG" 2>&1
  fi
  exec "\$APP_BIN" \$PERF_FLAGS "\$@" >>"\$LOG" 2>&1
fi

echo "[\$(date -Is)] packaged app missing; falling back to: \$HERMES_BIN desktop --skip-build" >>"\$LOG"
if [ -e "\$SANDBOX" ] && ! ok; then
  export ELECTRON_FORCE_NO_SANDBOX=1
fi
exec "\$HERMES_BIN" desktop --skip-build >>"\$LOG" 2>&1
EOF
  chmod 755 "$WRAPPER"
  log "Installed launch wrapper -> $WRAPPER"
}

configure_sandbox() {
  if [ ! -e "$CHROME_SANDBOX" ]; then
    warn "chrome-sandbox not found at: $CHROME_SANDBOX"
    warn "Skipping sandbox setup (set HERMES_UNPACKED to the linux-unpacked dir)."
    install_wrapper   # still install wrapper; it no-ops if file is missing
    return 0
  fi
  if _sandbox_ok; then
    log "Electron sandbox helper already configured (root:root 4755)."
  else
    log "Configuring Electron sandbox helper (sudo required, one time)..."
    if [ "$(id -u)" = "0" ] || have sudo; then
      _apply_sandbox_perms || true
    else
      warn "sudo not available; run as root: chown root:root '$CHROME_SANDBOX' && chmod 4755 '$CHROME_SANDBOX'"
    fi
    _sandbox_ok && log "Electron sandbox helper configured (root:root 4755)." \
                || warn "Sandbox helper still not root:root 4755."
  fi
  install_wrapper
}

uninstall() {
  rm -f "$DESKTOP_FILE"
  for s in "${ICON_SIZES[@]}"; do
    rm -f "$ICON_BASE/${s}x${s}/apps/$APP_ID.png"
  done
  rm -f "$ICON_BASE/scalable/apps/$APP_ID.png"
  rm -f "$WRAPPER"
  rmdir "$(dirname "$WRAPPER")" 2>/dev/null || true
  refresh_caches
  log "Removed '$APP_NAME' launcher, icons, and wrapper."
  log "Note: chrome-sandbox setuid bit is left as-is (root:root 4755)."
  exit 0
}

refresh_caches() {
  if have update-desktop-database; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  if have gtk-update-icon-cache; then
    # -t tolerates a missing index.theme; ignore failure on minimal installs.
    gtk-update-icon-cache -f -t "$ICON_BASE" >/dev/null 2>&1 || true
  fi
}

# --- arg parsing -----------------------------------------------------------
case "${1:-}" in
  --uninstall|-u) uninstall ;;
  --reset-state) RESET_STATE=1 ;;
  -h|--help)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "" ) RESET_STATE=0 ;;
  * ) die "Unknown argument: $1 (use --reset-state, --uninstall, or --help)" ;;
esac

# --- sanity: launcher ------------------------------------------------------
if [ ! -x "$HERMES_APP_BIN" ] && [ ! -x "$HERMES_BIN" ] && ! have "$HERMES_BIN"; then
  die "hermes launcher not found/executable at: $HERMES_BIN
       Set HERMES_BIN=/path/to/hermes and re-run."
fi

if [ ! -x "$HERMES_APP_BIN" ]; then
  warn "packaged Hermes app not found at: $HERMES_APP_BIN"
  warn "Launcher will fall back to 'hermes desktop --skip-build'."
fi

if [ "${RESET_STATE:-0}" = "1" ]; then
  reset_desktop_state
fi

# --- resolve a source icon -------------------------------------------------
src_icon=""
if [ -n "${ICON_SRC:-}" ] && [ -f "${ICON_SRC:-}" ]; then
  src_icon="$ICON_SRC"
elif [ -f "$ICON_BUILT" ]; then
  src_icon="$ICON_BUILT"
elif [ -f "$ICON_SOURCE" ]; then
  src_icon="$ICON_SOURCE"
else
  log "No local icon found; downloading official icon from:"
  log "  $ICON_URL"
  tmp_icon="$(mktemp --suffix=.png)"
  if have curl && curl -fsSL "$ICON_URL" -o "$tmp_icon"; then
    src_icon="$tmp_icon"
  elif have wget && wget -qO "$tmp_icon" "$ICON_URL"; then
    src_icon="$tmp_icon"
  else
    die "Could not obtain an icon. Place an icon at:
       $ICON_BUILT  (or)  $ICON_SOURCE
       or set ICON_SRC=/path/to/icon.png and re-run."
  fi
fi

# --- install icon at multiple sizes ----------------------------------------
for s in "${ICON_SIZES[@]}"; do
  dir="$ICON_BASE/${s}x${s}/apps"
  mkdir -p "$dir"
  resize_icon "$src_icon" "$dir/$APP_ID.png" "$s"
done
# A copy under scalable/ helps themes that prefer it; harmless if ignored.
mkdir -p "$ICON_BASE/scalable/apps"
cp -f "$src_icon" "$ICON_BASE/scalable/apps/$APP_ID.png"
log "Installed icon at sizes: ${ICON_SIZES[*]} (source: $src_icon)"

# --- install .desktop launcher --------------------------------------------
mkdir -p "$APPS_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=AI Agent
Comment=Launch the Hermes Desktop app
Exec=$WRAPPER
Icon=$APP_ID
Terminal=false
Categories=Development;
Keywords=hermes;agent;ai;
StartupNotify=true
StartupWMClass=Hermes
SingleMainWindow=true
DBusActivatable=false
EOF
chmod 644 "$DESKTOP_FILE"
log "Installed launcher -> $DESKTOP_FILE"

# --- configure Electron sandbox so the GUI launch needs no sudo ------------
configure_sandbox

# --- validate (best effort) ------------------------------------------------
if have desktop-file-validate; then
  desktop-file-validate "$DESKTOP_FILE" \
    && log "desktop-file-validate: OK" \
    || warn "desktop-file-validate reported issues (entry still usable)."
fi

# --- refresh caches --------------------------------------------------------
refresh_caches

# --- done / hints ----------------------------------------------------------
log ""
log "Done. '$APP_NAME' should now appear in your Applications menu."
session="${XDG_SESSION_TYPE:-unknown}"
if [ "$session" = "wayland" ]; then
  log "Wayland session detected — if it doesn't appear, log out and back in."
elif [ "$session" = "x11" ]; then
  log "X11 session detected — if it doesn't appear, run: killall -HUP gnome-shell"
else
  log "If it doesn't appear immediately, log out and back in."
fi
