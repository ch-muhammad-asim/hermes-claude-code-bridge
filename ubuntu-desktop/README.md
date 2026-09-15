# 🖥️ Hermes Desktop Launcher for Ubuntu/Debian

This folder installs **Hermes Desktop** as a proper Ubuntu/Debian desktop application so it appears in the Applications grid, can be searched, and can be pinned to the dock. 🚀✨

## 📁 Files

```text
ubuntu-desktop/
├── README.md                       # 👈 You are here
├── install.sh                      # 🛠️ Desktop launcher installer / uninstaller
├── install-claude-bridge.sh         # 🔌 Claude Code bridge systemd installer (portable, self-contained)
├── verify-perf.sh                  # 🏎️ Confirms the desktop launched with GPU acceleration
├── hermes-icon-512.png             # 🖼️ Prebuilt app icon
└── hermes-icon-source.png          # 🎨 Source icon fallback
```

## ✅ What The Installer Does

`install.sh` is idempotent, so it is safe to re-run any time. It:

- 🧩 creates a `.desktop` launcher for **Hermes Desktop**
- 🖼️ installs icons under the XDG hicolor icon theme
- 🚀 installs a launch wrapper at `~/.local/share/hermes-desktop/launch-hermes-desktop.sh`
- 🔐 configures Electron's `chrome-sandbox` helper as `root:root 4755` when available
- 🧯 optionally resets stale Electron renderer/cache state
- 🧹 can uninstall the launcher/icons/wrapper cleanly

## ⚡ Quick Install

Run from this directory:

```bash
cd hermes-claude-code-bridge/ubuntu-desktop
chmod +x ./install.sh
./install.sh
```

Then open the desktop launcher:

```text
Activities / Applications → search "Hermes Desktop" 🧠
```

## 🔁 Refresh After A Hermes Update

If Hermes was updated, re-run the installer to refresh the launcher, icons, wrapper, and Electron sandbox permissions:

```bash
cd hermes-claude-code-bridge/ubuntu-desktop
./install.sh
```

## 🧯 Reset Stale Desktop State

If the GUI opens blank, crashes, or keeps stale renderer state, use:

```bash
cd hermes-claude-code-bridge/ubuntu-desktop
./install.sh --reset-state
```

This moves Electron cache/storage folders from:

```text
~/.config/Hermes/
```

to a timestamped backup directory such as:

```text
~/.config/Hermes/reset-backup-YYYYMMDD-HHMMSS/
```

## 🧹 Uninstall

Remove the desktop launcher, installed icons, and wrapper:

```bash
cd hermes-claude-code-bridge/ubuntu-desktop
./install.sh --uninstall
```

> ℹ️ The installer intentionally leaves the Electron `chrome-sandbox` setuid bit as-is during uninstall.

## ⚡ Performance — GPU & Fast Startup

Older versions of this wrapper shipped with **GPU disabled** and **self-update enabled** on every launch, which made Hermes Desktop feel sluggish and slow to open. The current wrapper flips both defaults: 🏎️

| Setting | Old default | New default | Effect |
|---|---|---|---|
| 🎮 `HERMES_DESKTOP_DISABLE_GPU` | `1` (off) | `0` (hardware accel ON) | Snappy scrolling/rendering; uses your Intel/NVIDIA GPU |
| 🔄 `HERMES_DESKTOP_DISABLE_SELF_UPDATE` | `0` (update each launch) | `1` (skip updates) | Cold start drops from ~10–30s to ~2–4s |
| 🧪 `HERMES_DESKTOP_ELECTRON_FLAGS` | unset | tuned defaults below | Hardware video decode + zero-copy + larger V8 heap |

Default Electron flags applied to the packaged Hermes app: 🧰

```
--enable-zero-copy
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-features=UseOzonePlatform,VaapiVideoDecodeLinuxGL
--js-flags=--max-old-space-size=4096
```

### 🛠️ Override Per-Launch

```bash
# Pull the latest fork build this one launch
HERMES_DESKTOP_DISABLE_SELF_UPDATE=0 gtk-launch hermes-desktop

# Debug a GPU bug by forcing software rendering
HERMES_DESKTOP_DISABLE_GPU=1 gtk-launch hermes-desktop

# Replace the entire flag list (don't merge — total override)
HERMES_DESKTOP_ELECTRON_FLAGS="--disable-frame-rate-limit" gtk-launch hermes-desktop
```

### 🩺 Verify GPU Acceleration Is Live

Once Hermes Desktop is running, open the DevTools URL bar (`Ctrl+Shift+I`) → address `chrome://gpu` and look for: ✅

- **Hardware accelerated** ✅ next to `Canvas`, `Compositing`, `Raster`, `Video Decode`
- **OpenGL renderer**: should mention your GPU (e.g. `Intel Iris Xe Graphics`, `NVIDIA MX350`) — **not** `SwiftShader` or `LLVMpipe` (those = software fallback 🐌)

Or from a terminal:

```bash
grep "perf_flags\|launching packaged" ~/.local/state/hermes-desktop.log | tail -3
```

### 🧹 If Things Look Wrong After Upgrade

The GPU cache might be stale from the software-rendering era:

```bash
./install.sh --reset-state
```

That clears `~/.config/Hermes/{GPUCache,DawnCache,Cache,Code Cache}` (with a timestamped backup) so Electron re-builds them under the new flags. 🧼

## ⚙️ Environment Overrides

You can override paths without editing the script:

| Variable | Purpose | Default |
|---|---|---|
| `HERMES_BIN` | Hermes CLI launcher fallback | `~/.local/bin/hermes` |
| `HERMES_UNPACKED` | Hermes Electron unpacked app directory | `~/.hermes/hermes-agent/apps/desktop/release/linux-unpacked` |
| `HERMES_APP_BIN` | Packaged Hermes Electron binary | `$HERMES_UNPACKED/Hermes` |
| `ICON_SRC` | Custom icon source file | bundled icon, then official download fallback |
| `ICON_URL` | Download fallback icon URL | `https://raw.githubusercontent.com/ch-muhammad-asim/hermes-claude-code-bridge/main/ubuntu-desktop/hermes-icon-512.png` |
| `APP_NAME` | Display name in application launcher | `Hermes Desktop` |
| `HERMES_DESKTOP_DISABLE_GPU` | Force software rendering (set `1` to disable GPU accel) | `0` (GPU ON) |
| `HERMES_DESKTOP_DISABLE_SELF_UPDATE` | Skip self-update at launch | `1` (skip — set `0` to update) |
| `HERMES_DESKTOP_ELECTRON_FLAGS` | Full override of Electron perf flags | tuned defaults (see Performance) |

Example:

```bash
APP_NAME='Hermes Desktop Dev' \
HERMES_BIN="$HOME/.local/bin/hermes" \
./install.sh
```

## 🔍 Verify Installation

```bash
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/hermes-desktop.desktop"
WRAPPER="${XDG_DATA_HOME:-$HOME/.local/share}/hermes-desktop/launch-hermes-desktop.sh"

printf 'desktop_file='; test -f "$DESKTOP_FILE" && echo yes || echo no
printf 'wrapper='; test -x "$WRAPPER" && echo yes || echo no
printf 'icon_512='; test -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps/hermes-desktop.png" && echo yes || echo no
```

## 🪵 Logs

The GUI wrapper logs launch output here:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/hermes-desktop.log
```

Inspect it with:

```bash
sed -n '1,220p' "${XDG_STATE_HOME:-$HOME/.local/state}/hermes-desktop.log"
```

## 🛟 Troubleshooting

| Symptom | Fix |
|---|---|
| 🖱️ App does not appear in launcher | Re-run `./install.sh`, then log out/in or restart the shell |
| 🧱 GUI does not open from menu | Check `~/.local/state/hermes-desktop.log` |
| 🔐 Sandbox permission warning | Run `./install.sh` from a terminal so `sudo` can repair `chrome-sandbox` |
| 🧊 Blank/stale window | Run `./install.sh --reset-state` |
| 🖼️ Icon looks wrong | Install ImageMagick (`magick` or `convert`) and re-run `./install.sh` |
| 🧭 Hermes binary is elsewhere | Set `HERMES_BIN=/path/to/hermes ./install.sh` |

## 🔐 Safety Notes

- ✅ No secrets are stored by this installer.
- ✅ No standing passwordless sudo rule is created.
- ✅ Privilege elevation is limited to fixing Electron `chrome-sandbox` ownership/mode when needed.
- ✅ The wrapper uses `pkexec` only when a GUI launch detects the sandbox bit is missing.
- 🚫 Do not commit local logs, desktop cache folders, or credentials.

---

# 🔌 Claude Code bridge — `install-claude-bridge.sh`

Separate, self-contained installer for the **Claude Code bridge** (an OpenAI-compatible HTTP bridge that turns the `claude` CLI into a `/v1/chat/completions` endpoint that Hermes can call). 🛰️

## 🎯 What It Does

`install-claude-bridge.sh` is fully portable — the entire Python bridge is **embedded** inside the bash script (~464 lines of Python via heredoc), so you can `scp` just this one file onto a fresh Ubuntu 22.04 / 24.04 box and run it. It:

- 📄 Writes the embedded bridge to `~/.local/share/claude-code-bridge/claude_code_bridge.py`
- ⚙️ Installs a systemd unit at `/etc/systemd/system/claude-code-bridge.service`
- 🔁 Enables `--now` so it auto-starts at boot and restarts on failure
- 🧩 Patches `~/.hermes/config.yaml` to register a custom provider (with a dated `.bak` backup the first time per day)
- 🧪 End-to-end tests `/health`, `/v1/models`, and `/v1/chat/completions` after install
- 🧹 Has a clean `--uninstall` path
- 🧠 Resolves `$HOME` dynamically — no hardcoded home paths

## ⚡ Quick Install

```bash
cd /path/to/ubuntu-desktop
chmod +x ./install-claude-bridge.sh
./install-claude-bridge.sh
```

Expected output ends with: ✅
```
✔ Got from Claude: claude-code-bridge ok
Claude Code bridge installed.
  Endpoint:     http://127.0.0.1:18181/v1
  Model ID:     claude-opus-5-proxy
  Service:      claude-code-bridge.service (active)
```

## 🧭 Connect Hermes To The bridge

In Hermes' **"Local / custom endpoint"** setup screen:

| Field | Value |
|---|---|
| 🌐 Endpoint URL | `http://127.0.0.1:18181/v1` |
| 🔑 API key | *(leave empty)* — bridge ignores it unless started with `--api-key` |
| 🧠 Model | `claude-opus-5-proxy` |

Click **Connect**. The installer also writes this into `~/.hermes/config.yaml` automatically:

```yaml
model:
  default: claude-opus-5-proxy
  provider: custom
  base_url: http://127.0.0.1:18181/v1
  api_key: ''
```

## 🛠️ Environment Overrides

| Variable | Purpose | Default |
|---|---|---|
| `BRIDGE_HOST` | Bind address | `127.0.0.1` |
| `BRIDGE_PORT` | Listen port | `18181` |
| `CLAUDE_BIN` | Path to the `claude` CLI | `$HOME/.local/bin/claude` |
| `BRIDGE_CWD` | Working dir for the bridge | `$HOME` |
| `MODEL_ID` | Hermes-safe model alias the bridge advertises | `claude-opus-5-proxy` |
| `CLI_MODEL` | Real Claude model executed by the CLI | `claude-opus-5` |
| `BRIDGE_USER` | User the service runs as | `$SUDO_USER` or current user |
| `ALLOWED_TOOLS` | Comma-separated Claude Code tool allowlist | `*` |
| `DISALLOWED_TOOLS` | Comma-separated denylist | empty |
| `PERMISSION_MODE` | Claude Code permission mode | `bypassPermissions` |
| `PASS_MODEL` | Forward the model ID from the request instead of always using `MODEL_ID` | `0` |

Legacy `PROXY_HOST`, `PROXY_PORT`, `PROXY_CWD`, and `PROXY_USER` are still accepted for older install notes.

Example: change the port and run on a different model:

```bash
BRIDGE_PORT=18282 MODEL_ID=claude-sonnet-4-6 ./install-claude-bridge.sh
```

## 🧰 Default Tool Access

The Ubuntu Desktop bridge is a **local, full-trust Desktop integration**. By default it starts Claude Code with:

```text
--permission-mode bypassPermissions
--allowed-tools '*'
--disallowed-tools ''
```

That allows Hermes to use every Claude Code tool and connected Desktop connector available to the authenticated local user, including shell/file tools and any future connector added to Claude Code.

Verify after install:

```bash
curl -s http://127.0.0.1:18181/config | python3 -m json.tool | grep -A 12 allowed_tools
```

Lock it down per-machine if this is not a trusted Desktop:

```bash
ALLOWED_TOOLS="mcp__gcp,mcp__github" \
DISALLOWED_TOOLS="Bash,Edit,Write" \
PERMISSION_MODE="dontAsk" \
./install-claude-bridge.sh
```

## 🚦 Flags

| Flag | Effect |
|---|---|
| `--skip-hermes-config` | Install the service only — don't touch `~/.hermes/config.yaml` |
| `--skip-test` | Don't run any post-install HTTP test |
| `--quick` | Run `/health` + `/v1/models` but skip the slow chat completion |
| `--uninstall` / `-u` | Stop + disable the service, remove unit file + installed bridge |
| `--help` / `-h` | Print this script's header doc |

> 💡 Re-running the installer with `--quick --skip-hermes-config` takes **~1 second** when nothing has changed — the unit file is diffed against the installed version and `daemon-reload` is skipped if identical. 🏎️

## 🛡️ Systemd Safety Controls

The unit keeps resource limits and non-privilege controls, but it deliberately avoids home/filesystem sandboxing so Claude Code Desktop tools can operate normally:

| Directive | Value | Why |
|---|---|---|
| 🧊 `MemoryMax` | 2G | Cap parent+children RSS so a runaway `claude` subprocess can't OOM the desktop |
| 🌊 `MemoryHigh` | 1G | Throttle memory pressure before the hard cap |
| 🧵 `TasksMax` | 128 | Limit thread/process count |
| 📂 `LimitNOFILE` | 4096 | Lots of HTTP connections without exhausting fds |
| 🛟 `OOMScoreAdjust` | -200 | Less likely to be killed by the OOM killer than other user processes |
| 🚫 `NoNewPrivileges` | yes | Subprocesses can't gain privileges via setuid binaries |
| 🔓 `ProtectHome` / `ProtectSystem` | not enabled | Required for full Claude Code Desktop tools; restrictive home/filesystem sandboxes break Bash/Edit/Write and connector caches |
| 🧼 `PrivateTmp` | yes | Isolated temporary directory for the service |
| ⏱️ `RestrictRealtime` | yes | Prevents realtime scheduling abuse |
| 🧹 `RemoveIPC` | yes | Cleans IPC objects when the service user exits |
| 🧱 `SystemCallArchitectures` | native | Limits service execution to the native architecture |
| 🚀 `Restart` | always | Recover from any crash including OOM |
| ⏱️ `ExecStartPost` | health-gate | systemd waits for `GET /health` 200 before marking service active |

## 🩺 Built-in Readiness Gate

The unit's `ExecStartPost` polls `http://127.0.0.1:18181/health` up to 30× at 500ms intervals before declaring the service active. This means:

- ✅ `systemctl start claude-code-bridge` returns only after the HTTP port is listening
- ✅ Other systemd units that `After=claude-code-bridge.service` start only after the bridge is healthy
- ✅ The install script can drop its old polling loop — `systemctl restart` already blocks until ready

## 🔄 Updating Or Refreshing

The installer is **idempotent** — re-run any time to:

- 🔁 Refresh the embedded Python bridge if the script in this repo has changed
- ♻️ Reload the systemd unit and restart the service
- ➕ Re-apply the `~/.hermes/config.yaml` provider entry if Hermes wiped it

```bash
./install-claude-bridge.sh
```

## 🧪 Verify After Install

```bash
# Service health
systemctl status claude-code-bridge.service

# Live logs
journalctl -u claude-code-bridge.service -f

# Endpoint checks
curl -s http://127.0.0.1:18181/health
curl -s http://127.0.0.1:18181/v1/models | python3 -m json.tool

# Actual round-trip
curl -s -X POST http://127.0.0.1:18181/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"claude-opus-5-proxy","messages":[{"role":"user","content":"say hi"}]}' \
  | python3 -m json.tool
```

## 🧹 Uninstall

```bash
./install-claude-bridge.sh --uninstall
```

This stops the service, removes the systemd unit, deletes `~/.local/share/claude-code-bridge/`, and reloads systemd. It does **not** touch `~/.hermes/config.yaml` (revert manually if you want).

## 🛟 Troubleshooting (bridge)

| Symptom | Cause | Fix |
|---|---|---|
| 🔴 `claude binary not found` | `CLAUDE_BIN` wrong / Claude Code not installed | Install Claude Code, or set `CLAUDE_BIN=/abs/path/claude` |
| 🔴 `health check failed` | Port collision on `18181` | `BRIDGE_PORT=18282 ./install-claude-bridge.sh` |
| 🔴 Hermes still calls Anthropic directly | Hermes hasn't re-read its config | Restart the Hermes Desktop app |
| 🟡 `PyYAML missing` warning | `python3-yaml` not installed | `sudo apt install python3-yaml` then re-run |
| 🔴 502 from `/v1/chat/completions` | Claude CLI error | `journalctl -u claude-code-bridge.service -n 50` |

## 🔐 Safety Notes (bridge)

- 🔒 Default bind is `127.0.0.1` — bridge is **not** reachable from the network.
- ⚠️ Default tool access is intentionally broad for trusted Desktop use: `allowed_tools=*`, empty denylist, `bypassPermissions`.
- 🔑 If you need auth, start the bridge with an API key (env: `CLAUDE_CODE_BRIDGE_API_KEY`) — Hermes must then send it as `Authorization: Bearer <token>` or `x-api-key: <token>`.
- ⚠️ Changing `--host` to `0.0.0.0` exposes a code-executing endpoint to your LAN — combine with `--api-key` and firewall rules.

---
