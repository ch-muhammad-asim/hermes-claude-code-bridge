# 🐳 One-Script Docker Hermes + Claude Code

Use this when a developer already has Claude Code authenticated on their host
machine and needs a local Hermes dashboard that talks to that same Claude Code
session.

```text
Hermes dashboard/API
  -> claude-code-proxy
  -> host claude -p
```

## 📤 What To Share

Share this single file:

```text
docker-hermes-claude-bridge.sh
```

The script is self-contained. For the default host-proxy mode, it writes the
embedded Python proxy to a local hidden file automatically, so developers do not
need a separate `claude_code_proxy.py`.

## ✅ Prerequisites

The developer needs:

- Docker running.
- Claude Code already authenticated on the host.
- Host Claude Code auth files, normally:

```text
~/.claude
~/.claude.json
```

Quick host check:

```bash
claude -p "Reply with exactly: claude host ok"
ls -la ~/.claude
ls -la ~/.claude.json
```

## ▶️ Run

```bash
chmod +x ./docker-hermes-claude-bridge.sh
./docker-hermes-claude-bridge.sh up
```

Open Hermes:

```text
http://127.0.0.1:9119
```

Validate:

```bash
./docker-hermes-claude-bridge.sh status
curl -fsS http://127.0.0.1:18181/health
curl -fsS http://127.0.0.1:8642/health
```

After Claude Code has available session quota, run the full model validation:

```bash
./docker-hermes-claude-bridge.sh test
```

That is the normal handoff flow. No container-side Claude login is needed
because the proxy runs on the host and uses the already-authenticated host
`claude` command.

## 🚀 What The Script Starts

The script starts one host proxy process and one Hermes container:

```text
host claude-code-proxy process
  listens on 0.0.0.0:18181 on Linux, 127.0.0.1:18181 elsewhere
  runs claude_code_proxy.py with the host claude binary
  uses the developer's existing host Claude Code login

local-hermes-agent
  listens on 127.0.0.1:9119 for the dashboard
  listens on 127.0.0.1:8642 for the OpenAI-compatible API
  is configured to use http://host.docker.internal:18181/v1
```

Hermes config is written automatically into the `local-hermes-data` Docker
volume before the Hermes container starts.

Why host proxy? Testing showed the active Claude Code login is not reliably
portable into a Linux Docker container by copying `~/.claude` and
`~/.claude.json`; Claude Code can still report `Not logged in`. Running the
proxy on the host uses the same authenticated `claude` command the developer
already uses.

## ⚡ Useful Commands

```bash
./docker-hermes-claude-bridge.sh status
./docker-hermes-claude-bridge.sh logs
./docker-hermes-claude-bridge.sh logs proxy
./docker-hermes-claude-bridge.sh open
./docker-hermes-claude-bridge.sh mcp-callback 'http://localhost:<port>/oauth/callback?state=...&code=...'
./docker-hermes-claude-bridge.sh mcp-status
./docker-hermes-claude-bridge.sh restart
./docker-hermes-claude-bridge.sh stop
```

## 📋 Full Command Reference

| Command | Purpose |
|---|---|
| 🏗️ `build` | Build the proxy Docker image only (no containers started). |
| 🚀 `up` / `start` / `run` | Start host proxy + Hermes container. |
| 🔄 `restart` | Restart both containers in place. |
| 🛑 `stop` / `down` | Stop + remove containers. Add `--purge` to also delete Docker volumes. |
| 📈 `status` | Show container, proxy, and health state. |
| 🩺 `health` | `GET /health` against the proxy. |
| ⚙️ `config` | `GET /config` — proxy advertises its current flags. |
| ✅ `test` | End-to-end roundtrip: proxy → Claude CLI → response. |
| 📜 `logs [proxy]` | Tail Hermes (or proxy) logs. |
| 🌐 `open` | Open the Hermes dashboard URL in a browser. |
| 🔁 `mcp-callback URL` | Forward an OAuth callback URL back into the container. |
| 📊 `mcp-status` | Print MCP server config, auth cache, and recent log lines. |
| 🪪 `login` | Run `claude /login` on the host or in the proxy container. |
| 🐚 `shell` / `exec` | Open an interactive shell in the proxy container (`PROXY_RUNTIME=docker` only). |
| 📦 `extract DIR` | Materialize the Dockerfile, entrypoint, healthcheck and proxy.py into `DIR/` (for inspection or CI/CD). |
| 🆘 `help` / `-h` / `--help` | Print the script's full header doc. |

> 🔒 Mutating commands (`build`, `up`, `stop`, etc.) hold an exclusive `flock` on `.STACK_NAME.lock` so two concurrent invocations can't race on container/network creation. Read-only commands (`status`, `logs`, `health`) skip the lock. 🤝

Optional auth refresh:

```bash
./docker-hermes-claude-bridge.sh login
```

Use `login` only if the developer needs to refresh Claude Code auth. It runs
Claude Code on the host.

## 🔌 Add An MCP Server From The Web UI

Add MCP servers (for example a read-only GCP, GitHub, or kubectl MCP) from the
Hermes dashboard. Open:

```text
http://127.0.0.1:9119/mcp
```

Add a new remote MCP server. A typical stdio entry that proxies a remote MCP
endpoint looks like this:

```text
Name: <server-name>
Transport: stdio
Command: npx
Args: -y mcp-remote@latest <mcp-remote-url>
Environment: leave empty
```

Pick a short, lowercase `Name` with no typos; Hermes uses the server name when
registering MCP tools and logs.

If the server needs OAuth, `mcp-remote` prints an authorization URL. Open that
URL and approve access.

If the browser finishes at a URL like this and shows connection refused:

```text
http://localhost:<callback-port>/oauth/callback?state=...&code=...
```

copy the full callback URL from the browser address bar and bridge it back into
the Hermes container:

```bash
./docker-hermes-claude-bridge.sh mcp-callback \
  'http://localhost:<callback-port>/oauth/callback?state=...&code=...'
```

That works because the OAuth callback listener is created by `mcp-remote` inside
the Hermes container.

Check current MCP config, auth cache, and recent logs:

```bash
./docker-hermes-claude-bridge.sh mcp-status
```

If the MCP page shows the server but logs contain:

```text
Failed to connect to MCP server '<server-name>' (command=npx): CancelledError
```

then the stdio MCP process did not become ready before Hermes cancelled the
connection attempt. The common causes are:

- the first `npx -y mcp-remote@latest ...` run is still downloading;
- OAuth has not been completed yet;
- the server name or args were entered incorrectly.

Re-check status:

```bash
./docker-hermes-claude-bridge.sh mcp-status
```

Fix the server entry from the UI if needed, complete OAuth, and click
reconnect/restart from the UI. If it still fails, restart the local stack:

```bash
./docker-hermes-claude-bridge.sh restart
```

Remove containers and local Docker volumes:

```bash
./docker-hermes-claude-bridge.sh down --purge
```

`--purge` deletes Docker volumes but does not delete host `~/.claude` or host
`~/.claude.json`.

## ⚙️ Configuration

Set variables in the shell or a `.env` file next to the script.

| Variable | Default | Notes |
|---|---|---|
| `STACK_NAME` | `local-hermes` | Prefix for container, network, and Docker volume names. |
| `CONTAINER` | `${STACK_NAME}-claude-code-proxy` | Proxy container name. |
| `HERMES_CONTAINER` | `${STACK_NAME}-agent` | Hermes container name. |
| `NETWORK` | `${STACK_NAME}-net` | Docker network name. |
| `PROXY_RUNTIME` | `host` | Default uses host `claude`. `docker` is available only for experiments. |
| `HOST_PROXY_HOST` | `0.0.0.0` on Linux, `127.0.0.1` elsewhere | Host proxy bind address. Linux Docker containers cannot reach a host process bound only to loopback through `host.docker.internal`. |
| `HOST_CLAUDE_DIR` | `$HOME/.claude` | Host Claude Code auth/config directory checked before startup. |
| `HOST_CLAUDE_JSON` | `$HOME/.claude.json` | Host Claude Code login file checked before startup. |
| `HERMES_DASHBOARD_PORT` | `9119` | Host dashboard port. |
| `HERMES_API_PORT` | `8642` | Host Hermes API port. |
| `HERMES_BIND` | `127.0.0.1` | Host bind address for Hermes ports. |
| `PROXY_PORT` | `18181` | Host and container proxy port. |
| `PROXY_BIND` | `127.0.0.1` | Host bind address for the proxy. |
| `GATEWAY_ALLOW_ALL_USERS` | enabled by script | Enables local Web UI/gateway access for this developer-only stack. |
| `CLAUDE_CODE_PROXY_MODEL` | `claude-opus-4-8` | Default model when a request omits `model`. |
| `CLAUDE_CODE_PASS_MODEL` | `true` | Honor any Claude model ID the client requests (not limited to one model). Set `false` to pin the default. |
| `CLAUDE_CODE_MODELS` | `claude-opus-4-8,claude-sonnet-5,claude-haiku-4-5` | Models advertised on `/v1/models` (the picker catalogue). Not a whitelist. |
| `CLAUDE_CODE_EFFORT` | `max` | Claude Code effort (`low`/`medium`/`high`/`max`). |
| `CLAUDE_CODE_PERMISSION_MODE` | `dontAsk` | Do not prompt interactively for ungranted tools. |
| `CLAUDE_CODE_MAX_BUDGET_USD` | `1.00` | Empty string disables the proxy budget flag. |
| `CLAUDE_CODE_ALLOWED_TOOLS` | empty (no allowlist) | Comma-separated Claude Code tool allowlist. |
| `CLAUDE_CODE_DISALLOWED_TOOLS` | `Bash,Edit,Write,NotebookEdit` | Comma-separated denylist. |
| `CLAUDE_CODE_PROXY_API_KEY` | empty | Optional bearer token for the proxy. |
| `HERMES_API_KEY` | random per-run | Bearer token for the local Hermes API (override to pin). |
| `IMAGE` | `${STACK_NAME}-claude-code-proxy:local` | Proxy Docker image tag. |
| `HERMES_IMAGE` | `nousresearch/hermes-agent:v2026.7.20` | Hermes Docker image. Override to pin a specific release. |
| `NODE_BASE` | `node:22-bookworm-slim` | Base image for the proxy build. |
| `CLAUDE_CODE_VERSION` | `latest` | `@anthropic-ai/claude-code` npm version. |
| `CLAUDE_CODE_MAX_PROMPT_CHARS` | `200000` | Max chars in the prompt the proxy will forward to `claude`. |
| `CLAUDE_CODE_APPEND_SYSTEM_PROMPT` | guardrail prompt | Appended to every user prompt to enforce read-only behavior. |
| `HOST_PROXY_PID_FILE` | `.${STACK_NAME}-claude-code-proxy.pid` | Pid file for the host-mode proxy process. |
| `HOST_PROXY_LOG_FILE` | `.${STACK_NAME}-claude-code-proxy.log` | Log file for the host-mode proxy. |
| `HOST_PROXY_WORKSPACE` | `.${STACK_NAME}-workspace` | Working dir for the host-mode proxy. |
| `MEMORY` | `2g` | Proxy container memory cap. |
| `CPUS` | `1` | Proxy container CPU shares. |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | inherited from shell | Forwarded into both containers when set. |

If the host auth directory is somewhere else:

```bash
HOST_CLAUDE_DIR=/path/to/.claude \
HOST_CLAUDE_JSON=$HOME/.claude.json \
./docker-hermes-claude-bridge.sh up
```

If a developer wants a different local stack name:

```bash
STACK_NAME=my-hermes ./docker-hermes-claude-bridge.sh up
```

## 🛟 Troubleshooting

If the script fails with `host Claude Code auth directory not found` or
`host Claude Code login file not found`:

```bash
claude
# complete /login or setup-token on the host
./docker-hermes-claude-bridge.sh up
```

If Hermes opens but Claude requests fail, check host Claude first:

```bash
claude -p "Reply with exactly: host claude ok"
./docker-hermes-claude-bridge.sh logs proxy
```

If host Claude reports a usage/session limit, Hermes will also fail model calls
until that limit resets.

On Ubuntu/Linux, `Connection error` from Hermes usually means the host proxy is
not reachable from the Hermes container. Make sure the updated script is used,
or run this workaround:

```bash
HOST_PROXY_HOST=0.0.0.0 ./docker-hermes-claude-bridge.sh up
```

On Linux, if `~/.claude` is not readable inside Docker because of host file
permissions, either adjust permissions for the developer account or copy Claude
auth into a readable directory and run:

```bash
HOST_CLAUDE_DIR=/path/to/readable/.claude \
HOST_CLAUDE_JSON=/path/to/readable/.claude.json \
./docker-hermes-claude-bridge.sh up
```

## 🏎️ Performance & Hardening

### 🏗️ Build cache mounts

The generated Dockerfile uses **BuildKit cache mounts** for both apt and npm:

```dockerfile
# syntax=docker/dockerfile:1.7
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    ...
```

This persists the apt lists and the global npm cache between builds — `npm install -g @anthropic-ai/claude-code@X.Y.Z` is **instant** on re-installs. Typical rebuild times: 🏎️

| Build | Duration |
|---|---|
| 🥶 Cold (all layers fresh) | ~4 s |
| 🔥 Incremental (only `claude_code_proxy.py` changed) | ~1 s |

The COPY of fast-changing files (`claude_code_proxy.py`, `docker-entrypoint.sh`) happens **after** the heavy apt+npm layer, so editing the proxy script doesn't invalidate the package layer. 🎯

### 🛡️ Container hardening

Both containers run with strict defaults: 🔐

| Flag | Proxy | Hermes | Why |
|---|---|---|---|
| `--init` | ✅ | ✅ | tini reaps zombie subprocesses |
| `--cap-drop ALL` | ✅ | — | Proxy needs no Linux caps |
| `--security-opt no-new-privileges` | ✅ | ✅ | Block setuid escalation |
| `--user 1000:1000` | ✅ | — | Explicit non-root inside the container |
| `--tmpfs /tmp:size=256m` | ✅ | ✅ | In-memory /tmp; works with read-only |
| `--pids-limit 256` / `512` | ✅ | ✅ | Limit fork bombs |
| `--memory-swap=$MEMORY` | ✅ | ✅ | No swap thrashing |
| `--log-opt max-size=10m` | ✅ | ✅ | Cap log disk growth |
| `--log-opt max-file=3` | ✅ | ✅ | Rotate after 3 files |

### 🩺 Healthcheck

Health-check timing is `15s/3s/5s/3` (interval/timeout/start-period/retries) so a flapping proxy is marked unhealthy in ~45s. ⏱️

### 🔒 Concurrency lock

Mutating commands (`build`, `up`, `stop`, …) acquire an exclusive `flock` on `.STACK_NAME.lock`. Running two `up`s in parallel CI jobs is rejected with a clear error rather than racing on container/network creation. 🤝

### 🧪 Verify after install

```bash
# 1. Build hits the cache (should be < 5 s on rebuild)
time ./docker-hermes-claude-bridge.sh build

# 2. Container hardening
docker inspect $(./docker-hermes-claude-bridge.sh status --quiet 2>/dev/null || echo local-hermes-claude-code-proxy) \
  --format '{{.HostConfig.SecurityOpt}} {{.HostConfig.CapDrop}} {{.HostConfig.PidsLimit}} {{.HostConfig.Memory}}'

# 3. Concurrency lock
( ./docker-hermes-claude-bridge.sh build & ); ./docker-hermes-claude-bridge.sh build
# → expected: "another instance is holding ... .lock — refusing to run two builds concurrently"
```

## 🛟 Common Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| 🔴 `host Claude Code auth directory not found` | `~/.claude` missing or `HOST_CLAUDE_DIR` wrong | `claude` once to authenticate, then re-run `up` |
| 🔴 `another instance is holding ... .lock` | Two parallel `up`/`build` invocations | Wait for the first to finish; `rm` the lock only if you know there's no stale process |
| 🔴 `Connection error` from Hermes on Linux | Hermes container can't reach host proxy on loopback | Default already sets `HOST_PROXY_HOST=0.0.0.0` on Linux; ensure latest script |
| 🟡 `port already allocated` | Another stack uses `9119`/`8642`/`18181` | `STACK_NAME=alt PROXY_PORT=28181 HERMES_DASHBOARD_PORT=9120 ./docker-hermes-claude-bridge.sh up` |
| 🟡 BuildKit warning `the legacy builder is deprecated` | Old docker without buildx | `apt install docker-buildx-plugin` or use `DOCKER_BUILDKIT=1` env (set by the script) |
| 🔴 `Error: cannot resolve host.docker.internal` | Old Docker on Linux without `host-gateway` | Upgrade Docker to ≥ 20.10 or remove `--add-host host.docker.internal:host-gateway` |
| 🔴 Proxy `502: claude command failed` | Host `claude` session limit hit | Run `claude -p "say hi"` directly; resolve the upstream limit |
| 🟡 `flock(1) required` | `util-linux` missing (extremely rare) | `apt install util-linux` |

## 🔐 Security Notes

- Hermes dashboard/API ports bind to `127.0.0.1` by default.
- On Linux, the host proxy binds to `0.0.0.0` so the Hermes Docker container can
  reach it through `host.docker.internal`. Keep this for local developer
  machines only, or set a strong `CLAUDE_CODE_PROXY_API_KEY` and add network
  access controls.
- The host `~/.claude` directory and `~/.claude.json` file are
  credential-bearing. The default host-proxy mode uses them in place and never
  bakes them into an image.
- Write-capable tools are denied by default.
