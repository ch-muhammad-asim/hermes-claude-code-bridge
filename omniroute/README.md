# 🧭 OmniRoute — Unified AI Gateway

Self-hosted deployments of [**OmniRoute**](https://github.com/diegosouzapw/OmniRoute) — a local-first
gateway that puts **many AI providers behind one OpenAI-compatible endpoint**, so any tool that speaks
`/v1/chat/completions` can reach them through a single URL, with routing, fallback and cost controls in
front.

Where the rest of this repo *bridges one CLI* into an OpenAI-compatible endpoint
([Claude Code](../kubernetes) · [OpenCode](../opencode)), OmniRoute is the **fan-out layer**: one
endpoint, many upstream providers, chosen per request.

| Path | Target | Endpoint |
|------|--------|----------|
| [`docker/`](docker) | 🐳 Local laptop / any Docker host, via Compose | `http://localhost:20128/v1` |
| [`kubernetes/`](kubernetes) | ☸️ Cluster deployment: StatefulSet + PVC, Traefik TLS | `http://omniroute.omniroute.svc.cluster.local:20128/v1` |

```bash
# local
cd docker && cp env.example .env && ./generate-secrets.sh >> .env && docker compose up -d

# cluster
cd kubernetes && kubectl apply -k .        # render the Secret first — see its README
```

Then open the dashboard (`http://localhost:20128` locally) and add providers under
**Providers → Add connection**. Credentials are stored encrypted in OmniRoute's own database — not in
these manifests.

---

## 🔌 One endpoint, many providers

```text
  your tools ─┐
   (Hermes,   │        ┌──────────────────────────┐        ┌── Anthropic / OpenAI / Gemini …
    IDEs,     ├───────▶│  OmniRoute :20128        │───────▶├── OAuth + API-key providers
    scripts,  │  /v1   │  routing · fallback ·    │        ├── free tiers
    agents)   │        │  quotas · logging        │        └── local models
             ─┘        └──────────────────────────┘
```

The same port serves three surfaces: the **dashboard** (browser), the **OpenAI-compatible REST API**
(`/v1/...`), and an **MCP** endpoint for agents.

## 📌 Verified facts worth knowing up front

Everything below was checked against `diegosouzapw/omniroute:3.8.48` — locally with Docker Compose and
on a real Kubernetes API server — not copied from docs:

| Detail | Value |
|---|---|
| Image | `diegosouzapw/omniroute:3.8.48`, multi-arch (`linux/amd64` + `linux/arm64`) |
| Port | **20128 only** — dashboard, `/v1` API and MCP all share it |
| Health endpoint | **`/api/monitoring/health`** → `{"status":"healthy",...}` |
| Data | SQLite in **WAL** mode at `/app/data/storage.sqlite` (+ `-wal`, `-shm`) |
| Container user | non-root **uid/gid 1000** (`node`) |
| Idle memory | ~510 MiB RSS with the default 1024 MB Node heap ceiling |
| Boot time | ~15–25s to healthy (migrations + runtime hydration) |
| Redis | **optional** — unset `REDIS_URL` logs a notice and uses in-memory rate limiting |

> ⚠️ **`/health` and `/api/v1/health` return 404** on this version, despite appearing in some upstream
> docs. The endpoint the image's own healthcheck probes — and the one to use for Kubernetes probes and
> uptime monitors — is **`/api/monitoring/health`**.

> 🔓 **`REQUIRE_API_KEY` defaults to `false` upstream.** That means anything able to reach the port can
> spend your provider quota. The Kubernetes manifests here set it to `true`; keep it `false` only while
> the port is bound to loopback on your own machine.

## 🔐 Required secrets (both paths)

| Variable | Required | Generate | Purpose |
|---|---|---|---|
| `JWT_SECRET` | ✅ | `openssl rand -base64 48` | Signs dashboard session cookies |
| `API_KEY_SECRET` | ✅ | `openssl rand -hex 32` | Encrypts provider API keys at rest |
| `INITIAL_PASSWORD` | ✅ | your own strong value | First-boot dashboard login; hashed to bcrypt on startup |
| `STORAGE_ENCRYPTION_KEY` | ❌ | `openssl rand -hex 32` | Encrypts the whole SQLite DB — **back it up**, it cannot be recovered |
| `OMNIROUTE_WS_BRIDGE_SECRET` | ❌ | `openssl rand -hex 32` | WebSocket bridge secret; set it for any non-local deployment |

## 📚 Upstream references

- Source & docs: <https://github.com/diegosouzapw/OmniRoute>
- Docker guide: <https://github.com/diegosouzapw/OmniRoute/blob/main/docs/guides/DOCKER_GUIDE.md>
- Full env contract: <https://github.com/diegosouzapw/OmniRoute/blob/main/.env.example>
- Image tags: <https://hub.docker.com/r/diegosouzapw/omniroute/tags>

> This directory is a **deployment** of OmniRoute, not a fork — no upstream code is vendored here. Pin a
> release tag rather than `latest` so a redeploy is reproducible.
