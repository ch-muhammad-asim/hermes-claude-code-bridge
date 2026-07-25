# 🌉 Claude Code Bridge (with Hermes)

A **Claude Code–compatible bridge** that lets Hermes (or any chat-completions client)
drive an already-authenticated **Claude Code CLI**. It fulfils each request by
invoking `claude -p` and exposes it over a standard OpenAI-compatible endpoint
(`/v1/chat/completions`), translating the result back into that shape — so any
chat-completions client can talk to Claude Code.

Stdlib only — **no third-party dependencies and no Docker**. A single Python script
(`claude_code_bridge.py`) that runs directly on **macOS, Linux, and Windows** (Python 3.9+).

## Features

| Capability | Detail |
| --- | --- |
| Token usage / cost | parses `--output-format json` → real `usage` and logs `total_cost_usd` |
| Streaming | `--output-format stream-json` → **incremental** SSE deltas as Claude produces them |
| Model selection | forwards the client-requested model to `claude --model` (`--pass-model`, on by default) |
| Concurrency | bounded semaphore (`--max-concurrency`), fast `429` when saturated |
| System messages | mapped to `--append-system-prompt` |
| Timeouts | process-**group** kill (terminate → kill) so child processes die too |
| Lifecycle | graceful `SIGTERM`/`SIGINT` drain |
| Observability | `/health`, `/config`, `/metrics` (requests, errors, cost, in-flight); claude version in `/health` |
| Auth | constant-time bearer or `x-api-key` |

## Endpoints

- `GET /health` — status, bridge + claude versions, in-flight count
- `GET /config` — effective configuration
- `GET /metrics` — counters: requests, errors, rejected-busy, cost, output tokens
- `GET /v1/models`, `GET /v1/models/{id}`
- `POST /v1/chat/completions` — `stream: true|false`

## Run it (no Docker — macOS / Linux / Windows)

It runs directly wherever `python3` and the `claude` CLI are available.

**Any platform — run the script directly:**

```bash
python3 claude_code_bridge.py --port 18181 --model claude-opus-4-8 --max-concurrency 4
#  (Windows:  python claude_code_bridge.py --port 18181 ...)
```

`claude` is auto-detected from `PATH` (`claude` / `claude.cmd` / `claude.exe`);
override with `--claude-bin` or `CLAUDE_BIN` if it's installed elsewhere.

**Convenience launchers:**

```bash
# macOS / Linux
./run-bridge.sh            # start (127.0.0.1:18181)
./run-bridge.sh test       # /health + a chat completion
./run-bridge.sh selfcheck  # offline logic checks (no claude needed)
```

> 🪟 **Windows:** the PowerShell launcher, service installer, and bootstrap live in
> [`../windows`](../windows) (`run-bridge.ps1` / `install-claude-bridge.ps1`). The bridge
> itself is the same cross-platform `claude_code_bridge.py` shown above.

## Run as a persistent service (auto-start, all OSes)

One command installs a **per-user** background service that starts at login/boot and
restarts on crash — using each OS's native mechanism, no Docker:

| OS | Mechanism | Install |
| --- | --- | --- |
| macOS | launchd **LaunchAgent** (`~/Library/LaunchAgents`) | `./run-bridge.sh install-service` |
| Linux | **systemd `--user`** unit + `loginctl enable-linger` | `./run-bridge.sh install-service` |
| Windows | **Scheduled Task** at logon (hidden, auto-restart) | see [`../windows`](../windows) |

```bash
./run-bridge.sh install-service     # macOS / Linux
./run-bridge.sh service-status
./run-bridge.sh logs                # tail the service log
./run-bridge.sh uninstall-service
```

> 🪟 For the Windows Scheduled-Task equivalent, see [`../windows`](../windows).

It runs as a **user** service on purpose, so it inherits your authenticated Claude
Code login and its connectors. Current config (port/model/api-key/claude path) is
baked into the unit at install time — re-run `install-service` after changing it.
Logs go to `~/.claude-code-bridge.log`.

## Auth (Claude Code)

The bridge does **not** log in for you — it shells out to a `claude` that is
already authenticated on the machine (your `~/.claude` / `~/.claude.json`, or the
Windows equivalent under `%USERPROFILE%`). Authenticate Claude Code once on the
host, then start the bridge. If `/health` shows `claude_version: unknown` or
completions return `502`, `claude` isn't authenticated where the bridge runs.

## Point Hermes at it

Configure a Hermes custom provider (chat-completions transport):

```yaml
model:
  default: claude-opus-4-8
  provider: claude-code-bridge
  base_url: http://127.0.0.1:18181/v1
  api_mode: chat_completions
providers:
  claude-code-bridge:
    name: Claude Code Bridge
    base_url: http://127.0.0.1:18181/v1
    api_key: ${CLAUDE_CODE_BRIDGE_API_KEY}   # optional; omit if the bridge is unauthenticated
    default_model: claude-opus-4-8
    transport: chat_completions
```

(From a Hermes container reach the host bridge at `http://host.docker.internal:18181/v1`.)

## Configuration

Every flag has an env fallback (see `claude_code_bridge.py --help`). Key ones:

| Flag / env | Default | Purpose |
| --- | --- | --- |
| `--port` / `BRIDGE_PORT` | `18181` | listen port |
| `--model` / `CLAUDE_CODE_BRIDGE_MODEL` | `claude-opus-4-8` | model id |
| `--max-concurrency` / `CLAUDE_CODE_BRIDGE_MAX_CONCURRENCY` | `4` | max live `claude` processes |
| `--queue-wait` / `CLAUDE_CODE_BRIDGE_QUEUE_WAIT` | `30` | seconds to wait for a slot before `429` |
| `--timeout` / `CLAUDE_CODE_BRIDGE_TIMEOUT` | `240` | per-request seconds |
| `--permission-mode` / `CLAUDE_CODE_PERMISSION_MODE` | `bypassPermissions` | how Claude Code handles tool permissions |
| `--allowed-tools` / `CLAUDE_CODE_ALLOWED_TOOLS` | `*` | Claude Code tool allowlist. `*` = allow-all via the permission mode (no explicit allow rule is sent, since Claude Code rejects bare wildcards in allow rules). Set a comma-separated list to restrict. |
| `--disallowed-tools` / `CLAUDE_CODE_DISALLOWED_TOOLS` | (empty) | denylist |
| `--api-key` / `CLAUDE_CODE_BRIDGE_API_KEY` | (empty) | require a Bearer / `x-api-key` |
| `--pass-model` | on | forward the requested Claude model id instead of forcing the default |

> **Allow-everything by default (local Desktop).** Out of the box the bridge grants
> the CLI the full tool surface — `--permission-mode bypassPermissions`,
> `--allowed-tools '*'`, empty denylist — so Hermes gets *every* connected Claude
> Code tool/connector with no prompts. For a locked-down
> deployment, set `CLAUDE_CODE_ALLOWED_TOOLS` to an explicit list and/or
> `CLAUDE_CODE_DISALLOWED_TOOLS`, or change `--permission-mode`.

`CLAUDE_CODE_PROXY_*` environment variables are also accepted as fallbacks for
compatibility with the container-based deployment in [`../docker`](../docker).
