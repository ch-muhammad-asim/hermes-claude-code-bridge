# 🍎 macOS Deployment

Run the **Claude Code Bridge** natively on macOS — no Docker. This exposes an **OpenAI-compatible** HTTP endpoint on your Mac, backed by your already-authenticated **Claude Code** CLI, so any OpenAI SDK/tool (including the **Hermes Agent** desktop app) can use Claude locally. 🚀

---

## 📦 What's in this folder

| File | Purpose |
|------|---------|
| `install-claude-bridge.sh` | 🧰 One-shot bootstrap: Node.js LTS + Claude Code CLI + registers the bridge as a launchd service |
| `run-bridge.sh` | ▶️ Launcher + service manager (run foreground, install/uninstall the LaunchAgent, tail logs) |
| `claude_code_bridge.py` | 🌉 The stdlib-only Python bridge (OpenAI-compatible → `claude` CLI) |

---

## ✅ Prerequisites

- 🍎 macOS 12+ with the built-in `python3` (Xcode Command Line Tools) or Homebrew Python
- 🍺 [Homebrew](https://brew.sh) (used to install Node if it's missing)
- 🔑 An Anthropic account to authenticate Claude Code (browser login, one time)

> 🛡️ **No `sudo` needed.** Everything installs per-user and the LaunchAgent runs as **you**, so it inherits your interactive Claude Code login.

---

## ⚡ Quick Start

```bash
# 1) Authenticate Claude Code (opens a browser) - skip if already logged in
claude

# 2) Install everything + start the auto-start service
cd mac
./install-claude-bridge.sh
```

The bridge is now listening at **`http://127.0.0.1:18181/v1`** and restarts automatically at every login. 🎉

---

## 🔌 Test it directly

```bash
curl -s http://127.0.0.1:18181/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"claude-opus-4-8","messages":[{"role":"user","content":"Say hello from Claude Code"}]}'
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

> 🧠 **Two things are called "gateway".** The Hermes *gateway process* (messaging/cron) runs fine even when idle — that's not your problem. The desktop's **"Gateway needs setup"** pill and the empty model dropdown (`—`) mean **no model provider is configured**. Out of the box Hermes points at OpenRouter (needs a key); point it at the bridge instead.

Hermes treats any self-hosted OpenAI-compatible endpoint (vLLM, llama.cpp, this bridge) as provider **`custom`** — *not* `openai` or `auto` (those fail for a localhost URL).

**1. Configure the provider** in `~/.hermes/config.yaml` (back it up first: `cp ~/.hermes/config.yaml ~/.hermes/config.yaml.bak`):

```yaml
model:
  default: claude-opus-4-8
  provider: custom
  base_url: http://127.0.0.1:18181/v1
  key_env: OPENAI_API_KEY
```

The bridge ignores auth, but Hermes needs the env var named by `key_env` to exist:

```bash
echo 'OPENAI_API_KEY=not-needed' >> ~/.hermes/.env
```

*(Or via the UI: Settings → **Providers** → add a **Custom / OpenAI-compatible** provider with Base URL `http://127.0.0.1:18181/v1` and any non-empty key, then Settings → **Model** → pick `claude-opus-4-8`.)*

**2. Restart the gateway** so it picks up the change:

```bash
hermes gateway restart && hermes gateway status
```

**3. Verify the full path** Hermes → bridge → `claude`:

```bash
# what fills the model dropdown:
curl -s http://127.0.0.1:18181/v1/models | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data']])"
# end-to-end through Hermes:
hermes -z "Reply with exactly: end-to-end ok"     # -> end-to-end ok
```

Reopen the desktop — the "needs setup" pill is gone and the dropdown lists every model. To revert: `cp ~/.hermes/config.yaml.bak ~/.hermes/config.yaml && hermes gateway restart`.

---

## 🛠️ Managing the Service

```bash
./run-bridge.sh test              # 🩺 health check + a live completion
./run-bridge.sh selfcheck         # 🔬 offline logic checks (no claude needed)
./run-bridge.sh service-status    # 📊 LaunchAgent state
./run-bridge.sh logs              # 📜 tail the service log
./run-bridge.sh uninstall-service # 🧹 remove the LaunchAgent
./run-bridge.sh                   # ▶️ run in the foreground (Ctrl+C to stop)
```

The service is a per-user **launchd LaunchAgent** (`com.hermes.claude-code-bridge`) in `~/Library/LaunchAgents`, with `RunAtLoad` + `KeepAlive` so it starts at login and restarts on crash.

---

## ⚙️ Configuration

Set these before installing the service (they're baked into the LaunchAgent):

| Variable | Default | Description |
|----------|---------|-------------|
| `BRIDGE_HOST` | `127.0.0.1` | Bind address (keep it loopback) |
| `BRIDGE_PORT` | `18181` | Listen port |
| `CLAUDE_CODE_BRIDGE_MODEL` | `claude-opus-4-8` | Default model |
| `CLAUDE_CODE_BRIDGE_API_KEY` | *(empty)* | If set, clients must send `Authorization: Bearer <key>` |
| `CLAUDE_BIN` | *(auto)* | Explicit path to the `claude` binary |

```bash
# Example: require an API key and use a custom port
CLAUDE_CODE_BRIDGE_API_KEY="choose-a-strong-secret" BRIDGE_PORT=9000 ./install-claude-bridge.sh
```

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `claude` not found after install | Open a **new** terminal (PATH refresh), or re-run the installer |
| Health check not ready | First boot probes `claude` — wait a few seconds, then `./run-bridge.sh logs` |
| 401 from the endpoint | You set `CLAUDE_CODE_BRIDGE_API_KEY` — send it as `Authorization: Bearer <key>` |
| Hermes "Gateway needs setup" / dropdown shows `—` | No model provider configured — set the `custom` provider (see above) and `hermes gateway restart` |
| `Unknown provider 'openai'` | Use `provider: custom` (not `openai`) |
| `No LLM provider configured` | `provider: auto` can't infer a localhost URL — use `provider: custom` + `base_url` + `key_env` |
| `Address already in use` on the port | Another bridge already owns it — install yours on a free port: `BRIDGE_PORT=18182 ./install-claude-bridge.sh`, then set `base_url: http://127.0.0.1:18182/v1` and `hermes gateway restart` |

---

> 🪟 On Windows? See [`../windows`](../windows). 🐧 Linux? See [`../ubuntu-desktop`](../ubuntu-desktop). 🐳 Containers? See [`../docker`](../docker). ☸️ Production? See [`../kubernetes`](../kubernetes).
