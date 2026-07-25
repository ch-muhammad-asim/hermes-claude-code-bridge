# 🪟 Windows Desktop Deployment

Run the **Claude Code Bridge** natively on Windows 10/11 — no Docker, no WSL required. This exposes an **OpenAI-compatible** HTTP endpoint on your machine that is backed by your already-authenticated **Claude Code** CLI, so any OpenAI SDK/tool can talk to Claude locally. 🚀

---

## 📦 What's in this folder

| File | Purpose |
|------|---------|
| `install-claude-bridge.ps1` | 🧰 One-shot bootstrap: installs Python, Node.js LTS, the Claude Code CLI, and registers the bridge service |
| `run-bridge.ps1` | ▶️ Launcher + service manager (run in foreground, install/uninstall the auto-start service, tail logs) |
| `claude_code_bridge.py` | 🌉 The stdlib-only Python bridge (OpenAI-compatible → `claude` CLI) |

---

## ✅ Prerequisites

- 🪟 Windows 10 or 11 (PowerShell 5.1+ — ships in-box)
- 🌐 A working internet connection for the first install
- 🔑 An Anthropic account to authenticate Claude Code (browser login, one time)

> 🛡️ **No Administrator needed.** Everything installs per-user and the service runs as **you**, so it inherits your interactive Claude Code login.

---

## ⚡ Quick Start

Open a normal (non-admin) **PowerShell** window in this folder and run:

```powershell
# If script execution is blocked, allow it for THIS session only:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 1) Authenticate Claude Code (opens a browser) - skip if already logged in
claude

# 2) Install everything + start the auto-start service
.\install-claude-bridge.ps1
```

That's it. 🎉 The bridge is now listening at **`http://127.0.0.1:18181/v1`** and will restart automatically at every logon.

---

## 🔌 Use It

Point any OpenAI-compatible client at the local endpoint:

```powershell
$body = @{
  model    = "claude-opus-4-8"
  messages = @(@{ role = "user"; content = "Say hello from Claude Code" })
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://127.0.0.1:18181/v1/chat/completions" `
  -Method Post -ContentType "application/json" -Body $body
```

Python (OpenAI SDK):

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:18181/v1", api_key="not-needed")
print(client.chat.completions.create(
    model="claude-opus-4-8",
    messages=[{"role": "user", "content": "Say hello from Claude Code"}],
).choices[0].message.content)
```

---

## 🖥️ Connect the Hermes Agent desktop app

> 🧠 **Two things are called "gateway".** The Hermes *gateway process* (messaging/cron) runs fine even when idle. The desktop's **"Gateway needs setup"** pill and the empty model dropdown (`—`) mean **no model provider is configured** — point it at the bridge as a **`custom`** provider (`openai`/`auto` fail for a localhost URL).

**1. Configure the provider** in `%USERPROFILE%\.hermes\config.yaml` (back it up first):

```yaml
model:
  default: claude-opus-4-8
  provider: custom
  base_url: http://127.0.0.1:18181/v1
  key_env: OPENAI_API_KEY
```

The bridge ignores auth, but Hermes needs the env var named by `key_env` to exist — add a dummy to `%USERPROFILE%\.hermes\.env`:

```powershell
Add-Content "$env:USERPROFILE\.hermes\.env" "OPENAI_API_KEY=not-needed"
```

*(Or via the UI: Settings → **Providers** → add a **Custom / OpenAI-compatible** provider with Base URL `http://127.0.0.1:18181/v1` and any non-empty key, then Settings → **Model** → pick `claude-opus-4-8`.)*

**2. Restart the gateway** and **verify** the full path:

```powershell
hermes gateway restart
hermes -z "Reply with exactly: end-to-end ok"     # -> end-to-end ok
```

Reopen the desktop — the "needs setup" pill clears and the model dropdown lists every model.

---

## 🛠️ Managing the Service

```powershell
.\run-bridge.ps1 test             # 🩺 health check + a live completion
.\run-bridge.ps1 selfcheck        # 🔬 offline logic checks (no claude needed)
.\run-bridge.ps1 service-status   # 📊 is the service running?
.\run-bridge.ps1 logs             # 📜 tail the service log
.\run-bridge.ps1 uninstall-service # 🧹 remove the auto-start service
.\run-bridge.ps1                  # ▶️ run in the foreground (Ctrl+C to stop)
```

The "service" is a per-user **Scheduled Task** (`ClaudeCodeBridge`) that starts at logon, restarts on failure, and runs hidden.

---

## ⚙️ Configuration

Set these environment variables **before** installing the service (they're baked into the task at registration):

| Variable | Default | Description |
|----------|---------|-------------|
| `BRIDGE_HOST` | `127.0.0.1` | Bind address (keep it loopback unless you know why) |
| `BRIDGE_PORT` | `18181` | Listen port |
| `CLAUDE_CODE_BRIDGE_MODEL` | `claude-opus-4-8` | Default model |
| `CLAUDE_CODE_BRIDGE_API_KEY` | *(empty)* | If set, clients must send `Authorization: Bearer <key>` |
| `CLAUDE_BIN` | *(auto)* | Explicit path to the `claude` binary |
| `CLAUDE_CODE_BRIDGE_CWD` | `$HOME` | Working directory Claude Code runs in |

Example — require an API key and bind a custom port:

```powershell
$env:CLAUDE_CODE_BRIDGE_API_KEY = "choose-a-strong-secret"
$env:BRIDGE_PORT = "9000"
.\install-claude-bridge.ps1
```

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `claude` not found after install | Open a **new** PowerShell window (PATH refresh), or re-run the installer |
| `running scripts is disabled` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| Health check not ready | First boot probes `claude` — wait a few seconds, then `.\run-bridge.ps1 logs` |
| 401 from the endpoint | You set `CLAUDE_CODE_BRIDGE_API_KEY` — send it as `Authorization: Bearer <key>` |
| Hermes "Gateway needs setup" / dropdown shows `—` | No model provider configured — set the `custom` provider (see above) and `hermes gateway restart` |
| `Unknown provider 'openai'` | Use `provider: custom` (not `openai`) |
| `No LLM provider configured` | `provider: auto` can't infer a localhost URL — use `provider: custom` + `base_url` + `key_env` |

---

> 🍎 On a Mac? See [`../mac`](../mac). 🐧 On Linux? See [`../ubuntu-desktop`](../ubuntu-desktop). 🐳 Prefer containers? See [`../docker`](../docker). ☸️ Production Kubernetes? See [`../kubernetes`](../kubernetes).
