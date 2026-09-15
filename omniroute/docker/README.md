# 🐳 OmniRoute — local Docker Compose

Runs OmniRoute on your laptop (or any Docker host) from the **published multi-arch image** — nothing is
built from source, so it works the same on Apple Silicon, Intel and Linux.

Verified on Docker 29.4.0 / OrbStack with `diegosouzapw/omniroute:3.8.49`.

## 📦 Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | The stack: OmniRoute + an optional Redis profile |
| `env.example` | Documented environment contract — copy to `.env` |
| `generate-secrets.sh` | Prints the required secrets as ready-to-append `.env` lines |

## 🚀 Quick start

```bash
cd omniroute/docker

cp env.example .env
./generate-secrets.sh >> .env     # appends JWT_SECRET / API_KEY_SECRET / INITIAL_PASSWORD

docker compose up -d
docker compose logs -f            # watch it boot (~15-25s to healthy)
```

Then open **<http://localhost:20128>** — it redirects to `/dashboard`. Log in as the password from your
`.env` (`INITIAL_PASSWORD`), then add providers under **Providers → Add connection**.

> `.env` is gitignored (so are `.env.*`, which is why the template here is `env.example` without the
> leading dot). Real secrets can never be committed by accident.

## ✅ Verify it works

```bash
# 1. Container reports healthy (uses the image's own probe)
docker compose ps
#    NAME         STATUS
#    omniroute    Up ... (healthy)

# 2. Health endpoint — note the path: /api/monitoring/health
curl -fsS http://127.0.0.1:20128/api/monitoring/health
#    {"status":"healthy","version":"3.8.49",...}

# 3. OpenAI-compatible model list
curl -fsS http://127.0.0.1:20128/v1/models | head -c 200
```

`/health` and `/api/v1/health` **404** on this version — `/api/monitoring/health` is the real one.

## 🏷️ Which tag: `3.8.49` or `3.8.49-web`?

Docker Hub publishes both a plain and a `-web` tag for each release (plus `latest` / `latest-web`). Upstream
does not document the difference, so this was read straight out of the image build history:

| | `3.8.49` | `3.8.49-web` |
|---|---|---|
| Compressed size (amd64) | **461 MB** | **874 MB** |
| Layers | 13 | 16 |
| Entrypoint / Cmd / port / env / labels | identical | identical |

The `-web` image is the plain image plus exactly three layers:

```
COPY node_modules/playwright-core                          2.8 MB
COPY node_modules/playwright                               3.8 MB
RUN playwright install chromium --with-deps              406.7 MB
```

So **`-web` = the same app with Playwright and a headless Chromium baked in**, for features that need to
drive a real browser (web fetch/scrape/search). It costs ~413 MB extra and nothing else changes — same
entrypoint, same port, same environment contract, so it is a drop-in swap either way.

**This stack pins the plain tag.** Switch per-run without editing anything:

```bash
OMNIROUTE_VERSION=3.8.49-web docker compose up -d
```

## 🆓 Free models that work with zero credentials

OmniRoute advertises 400+ model ids, but most need a provider **connection** first. These were verified
to return a real completion on a fresh install with **no credentials at all** — $0 inference:

| Model id | Result |
|---|---|
| **`oc/deepseek-v4-flash-free`** ⭐ | ✅ HTTP 200, `finish_reason: stop` — OpenCode Zen free |
| `oc/ling-3.0-flash-free` | ✅ HTTP 200, `finish_reason: stop` — OpenCode Zen free |
| `auto/coding:free` / `auto/best-free` | ✅ over `curl` (route to `big-pickle`), but the Hermes TUI rejects their stream |
| `openrouter/nvidia/nemotron-3-nano-30b-a3b:free` | ✅ |
| `openrouter/inclusionai/ling-3.0-flash:free` | ✅ |
| `oc/laguna-s-2.1-free` | ⚠️ 429 rate-limited |
| other `oc/*-free` (minimax, qwen, trinity, nemotron, ling-2.6) | ❌ `401 … is not supported` |

> 💡 **Why a model can work in the OpenCode desktop app but 401 here.** The app is signed into your
> OpenCode Zen account; OmniRoute is a separate service with no OpenCode credentials of its own, so it
> advertises the id but the upstream call is rejected. Add **Providers → OpenCode Go** in the dashboard
> to unlock the rest.

**`oc/deepseek-v4-flash-free` is the recommended default** — a real OpenCode Zen free model that
answers with no setup. The `auto/*:free` combos self-heal across providers and are fine over `curl`,
but the Hermes TUI rejects their stream shape, so they are not used for the Kubernetes deployment.

## 🔧 Use it from your tools

Point any OpenAI-compatible client at the endpoint. With the shipped default
(`REQUIRE_API_KEY=false`, safe only because the port is on loopback) no key is needed:

```bash
curl -sS http://127.0.0.1:20128/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"oc/deepseek-v4-flash-free","messages":[{"role":"user","content":"Say: free ok"}],"max_tokens":300}'
```

> 🧠 **Give it enough `max_tokens`.** These are reasoning models: OmniRoute streams
> `reasoning_content` deltas before `content`, so a small budget (e.g. 32) is consumed entirely by
> reasoning and you get `finish_reason: length` with an **empty** `content`. 300+ returns real text.
>
> Responses are **SSE** (`data: {...}` lines) even when you don't pass `"stream": true` — parse the
> stream, or read `delta.content` across chunks.

Set `REQUIRE_API_KEY=true` in `.env` the moment the port is reachable from anywhere else, then mint a
key in **Settings → API Keys** and send it as `Authorization: Bearer <key>`.

## 🗄️ Data and persistence

State lives in a **SQLite database in WAL mode** on the `omniroute-data` named volume
(`/app/data/storage.sqlite` plus `-wal`/`-shm` sidecar files).

- A **named volume** is used rather than a host bind mount on purpose: the container runs as uid 1000
  (`node`), and Docker seeds a named volume with the image's ownership. A bind mount inherits host
  ownership and the app cannot write to it on first boot.
- `stop_grace_period: 40s` lets SQLite checkpoint the WAL on shutdown. Don't `docker kill` it.
- Verified: `docker compose down && docker compose up -d` preserves the database.

```bash
# back up the database (stop first for a clean, checkpointed copy)
docker compose stop
docker run --rm -v docker_omniroute-data:/data -v "$PWD:/backup" alpine \
  tar czf /backup/omniroute-backup.tgz -C /data .
docker compose start
```

> ⚠️ `docker compose down -v` **deletes the volume** and every provider connection, key and log with it.

## ⚡ Optional Redis

Redis is only needed for shared/persistent rate-limit state. Without it the log prints
`REDIS_URL is not set in production. Using in-memory rate limiting.` — fine for a single instance.

```bash
# 1. uncomment REDIS_URL=redis://redis:6379 in .env
# 2. start with the profile
docker compose --profile redis up -d
```

Verified behaviour: with `REDIS_URL` set the in-memory notice disappears, and if Redis is
**unreachable** OmniRoute still boots and stays healthy — it degrades instead of crashing. No
`depends_on` is therefore required.

## 🧹 Common operations

```bash
docker compose logs -f omniroute          # follow logs
docker compose restart omniroute          # restart (data kept)
docker compose pull && docker compose up -d   # upgrade after bumping OMNIROUTE_VERSION in .env
docker compose down                       # stop, keep data
docker compose down -v                    # stop and DESTROY data
```

## 🩺 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `env file ... /.env not found` | You skipped step one. `cp env.example .env && ./generate-secrets.sh >> .env`. The stack fails loudly rather than booting with no secrets — that's intentional. |
| `curl /health` → 404 | Wrong path. Use `/api/monitoring/health`. |
| Container `unhealthy`, empty logs | Still booting; the probe has a 40s `start_period`. Give it ~25s. |
| Dashboard login rejected | `INITIAL_PASSWORD` only applies on the **first** boot against an empty database. Change it in the dashboard, or wipe the volume to re-seed. |
| Provider OAuth redirects to the wrong host | Set `BASE_URL` **and** `NEXT_PUBLIC_BASE_URL` to the origin you actually use in the browser. |
| Permission errors on `/app/data` | You switched to a host bind mount. Either `chown -R 1000:1000 ./data` or go back to the named volume. |
| Port already in use | Change `PORT` in `.env`; the published port follows it. |
