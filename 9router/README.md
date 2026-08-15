# 🧭 9Router on Docker (named volumes)

[9Router](https://github.com/decolua/9router) is a local AI router and token optimizer. It sits between coding
agents (Claude Code, Codex, Cursor, Cline, OpenCode) and 40+ upstream providers, handling format translation
(OpenAI ↔ Anthropic ↔ Gemini), quota tracking, multi-account round-robin, and a 3-tier fallback chain
(subscription → cheap → free). It serves both a dashboard and an OpenAI-compatible `/v1` endpoint.

The app keeps its default port `20128` inside the container; this guide publishes it on host port **`8080`**
(`-p 8080:20128`). It also uses **named volumes** rather than the bind mount in upstream's
[DOCKER.md](https://github.com/decolua/9router/blob/master/DOCKER.md) — see
[Why named volumes](#-why-named-volumes) for the rationale.

If you would rather move the application itself to 8080 (so host and container ports match, `8080:8080`), a
ready-to-run stack for that is in [`docker-compose/`](docker-compose/) — it needs a couple of extra env vars,
which its [README](docker-compose/README.md) explains.

Port 8080 is a busy default — Tomcat, Jenkins, `kubectl proxy` and most local dev servers want it too. Check
it is free first:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

---

## 🚀 Quick start (docker run)

Create the volume and run the container:

```bash
docker volume create 9router-data
```

```bash
docker run -d --name 9router -p 8080:20128 -v 9router-data:/app/data -e DATA_DIR=/app/data --restart unless-stopped decolua/9router:0.5.55
```

Dashboard: <http://localhost:8080> — API base URL: `http://localhost:8080/v1`

`-p 8080:20128` is host port first, container port second. Nothing inside the container changes, so `PORT`
stays unset and the app goes on listening on 20128 — only the host-side number moves. To use a different host
port later, just change the left-hand side.

The published image `decolua/9router` supports `linux/amd64` and `linux/arm64`.

For the Compose equivalent, see [Quick start (docker compose)](#-quick-start-docker-compose).

### 🎯 Point an agent at it

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
```

Model selection, provider accounts and API keys are configured in the dashboard, not through env vars.

### 🩺 Check it is routing

9Router trusts loopback **inside the container**, which is not the same as the host's `localhost`. A request
from the host arrives through Docker's NAT with the bridge gateway as its source, so 9Router treats it as
remote and rejects it — `curl http://localhost:8080/v1/models` on the very machine running the container
still returns `{"error":"API key required for remote API access"}`.

The keyless check therefore has to run inside the container:

```bash
docker exec 9router node -e "fetch('http://127.0.0.1:20128/v1/models').then(r=>console.log(r.status))"
```

From anywhere else — including the host shell — generate a key in the dashboard's **Endpoints** section and
pass it. (`API_KEY_SECRET` is the HMAC secret those keys are signed with, not a key you can send.)

```bash
curl -s http://<host>:8080/v1/models -H "Authorization: Bearer <your-9router-key>" | head -40
```

`/v1/models` is answered by 9Router itself, so it costs no provider tokens. See
[Testing the API with curl](docker-compose/README.md#-testing-the-api-with-curl) for the completion call and
the header variants.

If provider OAuth logins (Claude Code, Codex, GitHub, Cursor) fail to redirect back after you change the host
port, set `BASE_URL` and `NEXT_PUBLIC_BASE_URL` to `http://localhost:8080` — the container has no way to know
which host port it was published on, so callback URLs it builds itself would otherwise point at 20128.

---

## 📦 Why named volumes

| | Bind mount (`$HOME/.9router`) | Named volume (`9router-data`) |
|---|---|---|
| Ownership / permissions | Host UID:GID must match the container user, or the DB fails to open | Docker creates the volume with the container's ownership |
| Portability | Path differs per host and per OS; breaks on Windows/WSL paths | Same command on macOS, Linux, Windows |
| Docker Desktop / OrbStack | Goes through the VM file-sharing layer — slow fsync, and SQLite is fsync-heavy | Lives in the VM's native filesystem — no sharing layer |
| Lifecycle | Deleted only by hand; easy to orphan or clobber | Managed by Docker (`docker volume ls/rm`, `docker compose down -v`) |
| Backup | `cp -a` on the host | `docker run --rm -v ... tar` (see [Backup](#-backup-and-restore)) |
| Accidental host writes | An editor or Spotlight can touch the SQLite file mid-write | Not reachable from the host filesystem |

The trade-off: you cannot `cd` into the data directory from the host. Use `docker exec` or a throwaway
`alpine` container when you need to inspect it. For a service whose state is a SQLite database, that is the
right trade.

`DATA_DIR=/app/data` must stay set — it is what tells 9Router to use the mount instead of its default
(`~/.9router/` on Unix, `%APPDATA%\9router\` on Windows). The database and its backups live under
`$DATA_DIR/db/`.

---

## 🐳 Quick start (docker compose)

The equivalent of the `docker run` command above. `docker-compose.yml`:

```yaml
services:
  9router:
    image: decolua/9router:0.5.55
    container_name: 9router
    restart: unless-stopped
    ports:
      - "8080:20128"
    environment:
      DATA_DIR: /app/data
    volumes:
      - 9router-data:/app/data

volumes:
  9router-data:
```

```bash
docker compose up -d
```

Keep the port mapping quoted. Unquoted, YAML's sexagesimal rules turn `MM:SS`-looking pairs into a single
integer — the classic case being `22:22` becoming `1342`. `8080:20128` is not affected, but quoting every
mapping is the habit that saves you the one time it matters.

### 🏷️ Volume naming under Compose

Compose prefixes volume names with the project name (the directory name by default), so the volume above is
created as `9router_9router-data`, *not* `9router-data`. Pin the project name to keep it predictable:

```bash
docker compose -p 9router up -d
```

To reuse a volume you created by hand — including one from the `docker run` quick start — declare it external:

```yaml
volumes:
  9router-data:
    external: true
```

That is the way to switch between the `docker run` and Compose forms without losing your provider accounts.

### 🗜️ With Headroom

Adds the [Headroom](#-what-is-headroom) compression sidecar on its own port:

```yaml
services:
  9router:
    image: decolua/9router:0.5.55
    container_name: 9router
    restart: unless-stopped
    ports:
      - "8080:20128"
    environment:
      DATA_DIR: /app/data
      HEADROOM_URL: http://headroom:8787
    volumes:
      - 9router-data:/app/data
    depends_on:
      - headroom

  headroom:
    image: ghcr.io/chopratejas/headroom:latest
    container_name: headroom
    restart: unless-stopped
    ports:
      - "8787:8787"
    volumes:
      - headroom-cache:/root/.cache/huggingface

volumes:
  9router-data:
  headroom-cache:
```

9Router reaches Headroom over the Compose network as `http://headroom:8787` — the service name, not
`localhost`. Publishing `8787` on the host is only needed if you want to hit Headroom directly; drop that
`ports` block otherwise and it stays internal.

`headroom-cache` is worth keeping — Headroom downloads its compression model on first run, and without the
volume every `docker compose down` throws it away.

---

## 🧠 What is Headroom?

[Headroom](https://github.com/chopratejas/headroom) is a separate open-source **context compression** service.
9Router's own RTK Token Saver trims tool output on the way through; Headroom goes further and compresses
everything the model *reads* — tool results, logs, RAG chunks, file contents, conversation history — before the
request leaves your machine. It is optional, off by default, and runs entirely locally.

### 🔌 How 9Router uses it

When `HEADROOM_URL` is set and the integration is enabled in the dashboard, 9Router POSTs the outbound message
array to Headroom's `/v1/compress` endpoint, gets a smaller message array back, and forwards *that* upstream.
The provider is never aware Headroom exists — the compression happens between your agent and the API call, so
no agent-side changes are needed.

```
Claude Code ──▶ 9Router ──▶ Headroom /v1/compress ──▶ 9Router ──▶ Anthropic / GLM / Vertex / …
                            (local, no network egress)
```

### ⚙️ How it compresses

A content router inspects each payload and dispatches it to a specialist:

- **SmartCrusher** — JSON and structured data (the big win: 60–95% token reduction). This is where `kubectl get
  -o json`, Terraform plans, and CloudWatch/Loki dumps land.
- **CodeCompressor** — AST-aware compression of source files, ~15–20%. Preserves structure rather than
  truncating.
- **Kompress-v2-base** — a HuggingFace model trained on agentic traces, for general prose and log text.
- **CacheAligner** — flags volatile content (timestamps, request IDs) that would otherwise change the prompt
  prefix on every turn and invalidate the provider's KV cache. It warns rather than rewriting.
- **CCR (reversible compression)** — originals are kept locally, so compressed content can be expanded again
  on demand instead of being lost.

Upstream benchmarks report ~92% reduction on code search and SRE debugging traces and ~73% on GitHub issue
triage, with accuracy held on GSM8K, TruthfulQA and SQuAD v2.

### 💡 Why it matters here

Long agent sessions are dominated by re-read context, not by generated tokens. On a rate-limited subscription
or a metered API key, compressing the read path is what extends the session — hence the name: it buys you
headroom under the context window and the quota. It matters most for exactly the payloads SRE work produces:
JSON API responses, log tails, and large diffs.

### 🖥️ Running it on the host instead

If you already run Headroom outside Docker (`pip install "headroom-ai[proxy]"` then
`headroom proxy --port 8787`), point the container at the host:

```bash
docker run -d --name 9router -p 8080:20128 -v 9router-data:/app/data -e DATA_DIR=/app/data -e HEADROOM_URL=http://host.docker.internal:8787 --restart unless-stopped decolua/9router:0.5.55
```

On macOS and Windows `host.docker.internal` resolves out of the box. On Linux, add
`--add-host=host.docker.internal:host-gateway` to the same command.

The Compose equivalent — no `headroom` service, `extra_hosts` for the Linux case:

```yaml
services:
  9router:
    image: decolua/9router:0.5.55
    container_name: 9router
    restart: unless-stopped
    ports:
      - "8080:20128"
    environment:
      DATA_DIR: /app/data
      HEADROOM_URL: http://host.docker.internal:8787
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - 9router-data:/app/data

volumes:
  9router-data:
```

Check the container can actually reach it (use `headroom` in place of `host.docker.internal` for the sidecar
setup):

```bash
docker exec 9router wget -qO- http://host.docker.internal:8787/health
```

---

## 🔧 Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DATA_DIR` | `~/.9router` / `%APPDATA%\9router\` | Data directory — set to `/app/data` to use the volume |
| `PORT` | `20128` | Container listen port — leave unset; the host port is set by `-p` instead |
| `HOSTNAME` | `0.0.0.0` | Bind address |
| `HEADROOM_URL` | unset | Headroom `/v1/compress` base URL; unset disables the integration |
| `JWT_SECRET` | generated | Dashboard session signing key — set it to keep sessions across recreates |
| `BASE_URL` / `NEXT_PUBLIC_BASE_URL` | `http://localhost:20128` | External URL — set to `http://localhost:8080` if OAuth callbacks misbehave, or to the public hostname behind a reverse proxy |
| `DEBUG` | unset | `true` for verbose logging |

---

## 🛠️ Operations

Stream logs:

```bash
docker logs -f 9router
```

Under Compose: `docker compose logs -f 9router`

Stop, start, remove:

```bash
docker stop 9router && docker start 9router
```

```bash
docker rm -f 9router
```

Under Compose, `docker compose stop` / `docker compose start` / `docker compose down`. Note `down` removes the
containers *and* the network but keeps volumes — only `down -v` deletes the data.

Removing the container leaves `9router-data` intact — re-run the `docker run` command (or `docker compose up
-d`) and every provider account, key and quota counter comes back.

### 🔍 Inspect the data directory

```bash
docker exec -it 9router ls -la /app/data/db
```

Or without a running container:

```bash
docker run --rm -v 9router-data:/data alpine ls -la /data/db
```

### ⬆️ Update

```bash
docker pull decolua/9router:0.5.55
```

```bash
docker rm -f 9router && docker run -d --name 9router -p 8080:20128 -v 9router-data:/app/data -e DATA_DIR=/app/data --restart unless-stopped decolua/9router:0.5.55
```

Under Compose:

```bash
docker compose pull && docker compose up -d
```

### 💾 Backup and restore

Stop the container first so SQLite is not mid-write. Back up to a tarball in the current directory:

```bash
docker stop 9router && docker run --rm -v 9router-data:/data -v "$PWD:/backup" alpine tar czf /backup/9router-data.tar.gz -C /data . && docker start 9router
```

Restore into a fresh volume:

```bash
docker volume create 9router-data && docker run --rm -v 9router-data:/data -v "$PWD:/backup" alpine tar xzf /backup/9router-data.tar.gz -C /data
```

### 🚚 Migrate an existing bind mount into a named volume

If you already ran 9Router against `$HOME/.9router`:

```bash
docker stop 9router && docker volume create 9router-data && docker run --rm -v "$HOME/.9router:/from" -v 9router-data:/to alpine cp -a /from/. /to/
```

Then remove the old container and re-run the quick start command. Keep `$HOME/.9router` around until you have
confirmed the dashboard still lists your provider accounts.

### 🧨 Remove everything

```bash
docker rm -f 9router && docker volume rm 9router-data
```

Under Compose: `docker compose down -v`

This deletes the database permanently — provider accounts and API keys have to be re-added.

---

## 📝 Notes

- Bind 9Router to loopback (`-p 127.0.0.1:8080:20128`, or `ports: ["127.0.0.1:8080:20128"]` under Compose) on
  any shared or internet-reachable host. The dashboard holds provider API keys and OAuth tokens, and 8080 is
  a port scanners check first.
- Set `JWT_SECRET` explicitly if you recreate the container often; otherwise every recreate logs you out.
- One 9Router per host is enough — multiple agents can share the same `/v1` endpoint.

### ☸️ Kubernetes

The same stack as manifests, with a secret generator, is in [`kubernetes/`](kubernetes/) — namespace, two
StatefulSets with PVCs, and `./generate.sh` for every credential.
