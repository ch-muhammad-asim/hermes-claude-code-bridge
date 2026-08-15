# 🐳 9Router + Hermes — Compose stack on port 8080

A ready-to-run [`docker-compose.yaml`](docker-compose.yaml) for [9Router](https://github.com/decolua/9router)
with the [Hermes agent](#-the-hermes-agent-service) alongside it, application and host port both **8080**.

| Service | Ports | Notes |
|---|---|---|
| `9router` | 8080 | Dashboard + OpenAI-compatible `/v1`. Healthchecked. |
| `hermes` | 8642 API, 9119 dashboard | Waits for 9Router to be *healthy*; needs a 9Router API key. |
| `headroom` | 8787 | Optional compression, behind `--profile headroom`. |

This differs from the [parent guide](../README.md), which leaves the app on its upstream default of `20128`
and only maps the host side (`-p 8080:20128`). Here both sides are 8080:

```yaml
ports:
  - "8080:8080"     # host:container
environment:
  PORT: "8080"      # moves the app itself off 20128
```

Matching ports means `docker ps`, the logs, the dashboard URL and any health check all agree on one number —
worth having when someone else has to debug the box at 3am. The cost is two extra env vars, below.

---

## 🚀 Run it

No setup file needed — every variable has a working default:

```bash
docker compose up -d
```

**For real secrets instead of the committed defaults, run the generator first** — it produces every value
described in this README, writes `.env`, and prints them:

```bash
./generate.sh --up
```

That is the whole install **and the repair command**. It generates secrets, starts the stack, waits for
9Router, mints an API key, recreates Hermes so it picks the key up, warms the model catalog so the picker
shows all ~690 models immediately, and finally verifies Hermes can actually reach 9Router — retrying once if
9Router was still initialising. Run it again any time something looks wrong.

The individual steps still work if you prefer them:

```bash
./generate.sh && docker compose up -d && ./generate.sh --key-only
```

> ⚠️ **After deleting the volumes** (`docker compose down -v`, or removing the `9router_*` volumes by hand)
> the stored API key is dead: 9Router generates a new machine id and purges keys bound to the old one. The
> stack comes up looking healthy, but every model call 401s and the picker shows **"9router · 1 models"**.
> `./generate.sh --up` detects and fixes this; a bare `docker compose up -d` cannot.

| Command | Does |
|---|---|
| `./generate.sh` | Generates all secrets → `.env` (backing up any existing one), then prints them |
| `./generate.sh --print` | Re-prints what is already in `.env` |
| `./generate.sh --key-only` | Mints/fetches the 9Router API key from the running stack into `.env` |
| `./generate.sh --rotate` | Forces new values for everything — **invalidates every issued 9Router API key** |

Re-running plain `./generate.sh` deliberately **reuses** the existing 9Router secrets. That is not laziness:
`MACHINE_ID_SALT` derives `/app/data/machine-id`, and changing it makes 9Router rewrite that file and purge
every API key bound to the old id — the rows vanish from its `apiKeys` table and Hermes' stored key starts
returning `401`. `API_KEY_SECRET` (the HMAC that signs keys) has the same effect, and `JWT_SECRET` invalidates
dashboard sessions. Only the Hermes credentials rotate on a normal re-run.

> 🔎 **"9router · 1 models" in the picker means the key is dead, or discovery has never run.** Hermes falls
> back to just the configured `default_model` rather than showing an error. Both causes are fixed by
> `./generate.sh --key-only`, which validates the stored key (re-minting it if 9Router no longer accepts it),
> recreates Hermes, and warms the catalog. Run it after any `docker compose down -v`.

`--key-only` is separate because 9Router cannot issue a key until it is running, and a fresh install has none.
`INITIAL_PASSWORD` is preserved across re-runs, since 9Router only honours it when initialising an empty
volume — `docker compose down -v` first if you want a new one. The Hermes password is shown once and is not
recoverable from its hash.

The rest of this README explains what those values are and how to produce them by hand.

9Router dashboard: <http://localhost:8080> — API base URL: `http://localhost:8080/v1`
Login password: **`changeme123`** (from `INITIAL_PASSWORD`, applied on first start).
Hermes dashboard: <http://localhost:9119> — Hermes API: `http://localhost:8642`

Hermes needs one more step before it can route anything: a 9Router API key in `.env`. See
[The Hermes agent service](#-the-hermes-agent-service).

That default password and the three placeholder secrets are fine for a local or throwaway box. Override them
via an optional `.env` before putting this anywhere reachable — see [Overriding the
defaults](#-overriding-the-defaults) and [VPS deployment](#-vps-deployment).

Point an agent at it:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8080
```

Provider accounts and API keys are added in the dashboard, not through env vars.

Check 8080 is free before you start — Tomcat, Jenkins, `kubectl proxy` and most local dev servers want it too:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

---

## 🤖 The Hermes agent service

The stack runs [Hermes](https://github.com/NousResearch) (`nousresearch/hermes-agent:v2026.8.13`) alongside
9Router, pointed at it for inference. Both come up with `docker compose up -d`.

```
hermes ──▶ http://9router:8080/v1 ──▶ provider (Claude Code / GLM / Vertex / …)
  :8642 API
  :9119 dashboard
```

### 🔐 It needs a 9Router API key

This is the part that catches people. Hermes reaches 9Router over the compose network, which is **not**
loopback from 9Router's side — so Hermes is a remote caller and the key rule from
[Testing the API](#-testing-the-api-with-curl) applies to it too. Without a key, Hermes starts cleanly and then
every model call returns `API key required for remote API access`.

Generate a key in the dashboard's **Endpoints** section, then:

```bash
printf 'NINEROUTER_API_KEY=%s\n' '<generated-key>' >> .env
```

```bash
docker compose up -d
```

It is passed to Hermes as `OPENAI_API_KEY`, which is the env var
[`hermes-config.yaml`](hermes-config.yaml) names in `key_env`.

### 🩺 Ordering and health

`hermes` declares:

```yaml
depends_on:
  9router:
    condition: service_healthy
```

`service_healthy` waits for 9Router's healthcheck to actually pass, rather than only for the container to be
created — which is what plain `depends_on` gives you, and it is not enough here: 9Router runs migrations on
first boot, so the port is accepting connections well before it can answer a model list. Hermes would come up,
fail its first inference call and sit in a restart loop.

9Router's check hits `/` rather than `/v1/models`, so it keeps working if you set `REQUIRE_API_KEY=true`. It
allows a 60s `start_period` for that first-boot migration; failures during that window do not count against
`retries`. Hermes checks its own `/health` on the API port, the same endpoint the Kubernetes manifests in this
repo probe.

Watch them converge:

```bash
docker compose ps
```

```bash
watch -n2 'docker inspect --format "{{.Name}} {{.State.Health.Status}}" 9router hermes'
```

`hermes` stays in `Created` until `9router` reports `healthy`.

#### 🚑 When `hermes` says `unhealthy`

`9router (healthy)` + `hermes (unhealthy)` means the dependency gate worked and Hermes is not answering
`/health` on 8642. The probe reports `curl: (7) Failed to connect to 127.0.0.1 port 8642`.

`curl` **is** present in the image, so a failing probe is almost never the probe's fault. In testing, both
causes were missing credentials — each one silently prevents a server from binding:

| Symptom in `docker compose logs hermes` | Cause | Fix |
|---|---|---|
| `Refusing to bind dashboard to 0.0.0.0 — … no auth providers are registered` repeating every few seconds | `HERMES_DASHBOARD_PASSWORD_HASH` empty. Hermes exits, `restart: unless-stopped` loops it. | Set the hash — see [Hermes dashboard password](#-hermes-dashboard-password). |
| Dashboard says `HERMES_DASHBOARD_READY`, but **no** `api_server` line anywhere | `API_SERVER_KEY` empty. The API server never binds and logs nothing at all. | Set `HERMES_API_SERVER_KEY` in `.env`. |

The second one is the nastier of the two — there is no error message, just an absence. Confirm it directly:

```bash
docker compose exec hermes sh -lc 'echo "ENABLED=$API_SERVER_ENABLED KEY_LEN=${#API_SERVER_KEY}"'
```

`KEY_LEN=0` is the tell. With a key set, the log gains an `[Api_Server]` line and the healthcheck passes
within seconds.

Both have working committed defaults in this stack, so a fresh `docker compose up -d` comes up healthy. You
hit these only after overriding one of them with an empty value in `.env` — an empty assignment is not the
same as leaving the line out.

Then the usual two:

```bash
docker compose logs --tail=80 hermes
```

```bash
docker inspect --format '{{json .State.Health}}' hermes | python3 -m json.tool
```

Note that an unhealthy Hermes still serves whatever it did manage to bind; `unhealthy` is the probe's verdict,
not a stop.

### 🔑 Hermes dashboard password

> 🚨 **This is not a "set a password" field, and it is not optional.** There is no first-run setup screen and
> no CLI command. You generate a password yourself, hash it with a helper that exists **only inside the Hermes
> image**, and pass the hash in as an environment variable.

**Leaving it unset does not mean "no login" — it means Hermes will not start.** With
`HERMES_DASHBOARD_HOST=0.0.0.0` and no auth provider configured, Hermes refuses to bind and exits:

```
Refusing to bind dashboard to 0.0.0.0 — the auth gate engages on non-loopback binds,
but no auth providers are registered.
There is no unauthenticated public-bind option — to keep it local, bind 127.0.0.1 and tunnel in.
```

`restart: unless-stopped` then restarts it in a loop, which from outside looks like a container that is `Up`
but permanently `unhealthy`. This stack therefore ships a **working default**: password `changeme123`
(the committed scrypt hash matches 9Router's default password), so `docker compose up -d` comes up healthy
with nothing else configured. That hash is public — replace it before exposing the box.

Four things that trip people up when you generate your own:

| ⚠️ Constraint | Why it bites |
|---|---|
| **Only the Hermes image can hash it** | The dashboard uses `scrypt` with Hermes' own parameters. `openssl dgst`, `python hashlib`, `htpasswd`, or any online generator produce a hash of the right *shape* that never verifies. |
| **The hashing image tag must equal the running tag** | Hash with `v2026.7.20` and run `v2026.8.13` and you may be verifying against a different build's parameters. Both commands below pin `v2026.8.13` — the tag this stack runs. |
| **The plaintext is unrecoverable** | Only the hash is stored. There is no reset flow — losing the plaintext means rotating, not recovering. Save it in the *same step* that generates it. |
| **Compose eats `$` in `.env`** | scrypt hashes are `$`-delimited. Unescaped, Compose reads `$scrypt` / `$ln` as variable references and substitutes empty strings, corrupting the hash before the container ever sees it. |

You also need a container engine running locally to do the hashing at all — Docker Desktop or OrbStack:

```bash
docker info >/dev/null 2>&1 && echo "✅ engine up" || echo "🛑 start Docker Desktop / OrbStack first"
```

**1️⃣ Generate the plaintext password and save it immediately.** Do this before hashing, not after:

```bash
export NEW_PASS="$(openssl rand -hex 24)" && echo "🔑 hermes dashboard: admin / $NEW_PASS"
```

Copy that line into your password manager now. Everything after this point is one-way.

**2️⃣ Hash it with the Hermes image.** The `--entrypoint` override runs the image's bundled Python against its
own `plugins.dashboard_auth.basic` module — this is the only supported way to produce the hash:

```bash
export HASH="$(docker run --rm --entrypoint /opt/hermes/.venv/bin/python -e PYTHONPATH=/opt/hermes -e P="$NEW_PASS" nousresearch/hermes-agent:v2026.8.13 -c 'import os;from plugins.dashboard_auth.basic import hash_password;print(hash_password(os.environ["P"]))')"
```

```bash
echo "$HASH"
```

You should see a `$`-delimited scrypt string shaped like this (this is the real format, from a verified run):

```
scrypt$16384$8$1$bhWPFafNKz9xpQtJ600mZw==$agW1/fYGtnsj8PLtP0N1ISxYf+Hp2d0sVL12q+5mfWg=
```

Empty output means the hash step failed — check the engine is running and the tag exists; do not continue
with an empty `$HASH`, because an empty hash is the crash-loop case above, not a passwordless dashboard.

**3️⃣ Write the hash and a session secret into `.env`, escaping every `$` as `$$`:**

```bash
printf 'HERMES_DASHBOARD_PASSWORD_HASH=%s\nHERMES_DASHBOARD_SECRET=%s\n' "$(printf '%s' "$HASH" | sed 's/\$/$$/g')" "$(openssl rand -hex 32)" >> .env
```

`HERMES_DASHBOARD_SECRET` signs dashboard sessions and is a *separate* value from the password hash — the
login will not hold a session without it. Both are required; so is `HERMES_DASHBOARD_USERNAME`, which defaults
to `admin`.

**4️⃣ Recreate the container** so the new environment is applied — `restart` alone re-runs the old env:

```bash
docker compose up -d --force-recreate hermes
```

**5️⃣ Verify the hash survived the round-trip.** This is the step that catches the `$` problem — the value
inside the container must match your `$HASH` exactly, with single `$`, not `$$` and not truncated:

```bash
docker compose exec hermes printenv HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH
```

```bash
echo "$HASH"
```

If the two differ, the `sed` escaping did not apply — fix the `.env` line and repeat step 4.

Then log in at <http://localhost:9119/login> as **`admin`** with the password from step 1. Sessions last 12h
(`HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200`).

Despite the `basic_auth` naming, the dashboard is a **login form**, not HTTP basic auth — `curl -u user:pass`
will not authenticate you, and `/` simply redirects to `/login?next=%2F`. To verify from the command line,
post to the same endpoint the form uses:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"provider":"basic","username":"admin","password":"<your-password>","next":"/"}' http://localhost:9119/auth/password-login
```

`200` means the credentials are good and a session cookie was issued; `401` with `{"detail":"Invalid
credentials"}` means the hash and the password disagree.

**If login still fails**, work through it in this order:

1. Confirm step 5 matches — a mangled hash is by far the most common cause.
2. Confirm you hashed with the same tag you are running: `docker compose images hermes`.
3. Confirm all three dashboard variables are present: `docker compose exec hermes env | grep HERMES_DASHBOARD`.
4. Check what the module actually exposes in your build, in case the helper was renamed:

```bash
docker run --rm --entrypoint /opt/hermes/.venv/bin/python -e PYTHONPATH=/opt/hermes nousresearch/hermes-agent:v2026.8.13 -c 'import plugins.dashboard_auth.basic as b;print([n for n in dir(b) if not n.startswith("_")])'
```

**To rotate**, repeat steps 1–5, but *replace* the two lines in `.env` rather than appending — duplicate keys
mean the last one wins, which makes for a confusing debug session. Rotating
`HERMES_DASHBOARD_SECRET` on its own invalidates every live session without changing the password.

### 🎛️ Adding 9Router as a custom endpoint

[`hermes-config.yaml`](hermes-config.yaml) is mounted **read-write** at `/opt/data/config.yaml` — read-write
because the dashboard's **Config** page writes to that path, and a `:ro` mount makes its SAVE button fail.

**Two blocks are required, and they do different jobs.** `providers.<key>` *defines* the endpoint;
`model.provider` *binds* the default chat to it:

```yaml
model:
  provider: 9router
  default: oc/mimo-v2.5-free

providers:
  9router:
    name: 9Router
    base_url: http://9router:8080/v1
    key_env: OPENAI_API_KEY
    api_mode: chat_completions
    default_model: oc/mimo-v2.5-free
    discover_models: true
```

> 🚨 **`model` as a bare string silently breaks this.** `model: oc/mimo-v2.5-free` is accepted, but
> `hermes_cli/config.py` only reads a provider when `model` is a **mapping** — as a string the provider
> resolves to empty and Hermes falls back to its built-in **Nous Research** provider, which it has no
> credentials for. Every chat then fails with:
>
> ```
> HTTP 401: Missing Authentication header
> ```
>
> That error is *not* from 9Router (whose wording is `API key required for remote API access`), so it sends
> you hunting for a key problem that does not exist — the `providers` block can be perfectly correct. The tell
> is in the dashboard's model badge: it reads **"mimo-v2.5-free · Nous Research"** instead of 9Router.

`key_env: OPENAI_API_KEY` resolves from the container's own environment — the compose file already passes
`NINEROUTER_API_KEY` in under that name. You do **not** need to create `$HERMES_HOME/.env`; that step from the
desktop guides is for a non-container install.

Entries are normalized by `_normalize_custom_provider_entry()`, which accepts `name`, `base_url`, `api_key`,
`key_env`, `api_mode`, `model`, `default_model`, `models`, `discover_models`, `context_length`, `extra_body`,
`extra_headers` and `ssl_verify`, plus camelCase aliases (`baseUrl`, `apiKey`, `keyEnv`).

Confirm both halves parsed — the provider entry *and* the binding. A `model` printed as a plain string is the
silent-fallback case above:

```bash
docker compose exec hermes sh -lc 'PYTHONPATH=/opt/hermes /opt/hermes/.venv/bin/python -c "from hermes_cli.config import load_config, get_compatible_custom_providers; c=load_config(); print(c.get(\"model\")); print(get_compatible_custom_providers(c))"'
```

Expected: `{'provider': '9router', 'default': 'oc/mimo-v2.5-free'}` followed by an entry whose
`provider_key` is `9router`.

Then the real end-to-end — this exercises Hermes' own model resolution, not just the network path:

```bash
docker compose exec hermes sh -lc '/opt/hermes/.venv/bin/hermes -z "Reply with exactly: ok"'
```

It should print `ok`. If it 401s, add `--provider 9router -m oc/mimo-v2.5-free`: succeeding *with* those flags
and failing without them confirms the binding is the problem, not the endpoint.

Or do it from the dashboard instead: **Config** → the `/opt/data/config.yaml` editor → SAVE, which writes the
same file.

#### Free models via OpenCode

9Router's **OpenCode Free** provider needs no credentials of its own — it shows `Ready` under
Providers → Free Tier with no connection to configure. Its ids are `oc/…`:

```bash
docker compose exec 9router node -e "fetch('http://127.0.0.1:8080/v1/models').then(r=>r.json()).then(j=>console.log(j.data.map(m=>m.id).filter(i=>i.startsWith('oc/')).join('\n')))"
```

At the time of writing that is `oc/mimo-v2.5-free` and `oc/deepseek-v4-flash-free`. Note the `opencode-go/…`
ids are a **different, non-free** provider — `oc/` is the free tier.

Verify a model end to end, from inside the Hermes container so it exercises the real path
(Hermes → 9Router → provider):

```bash
docker compose exec hermes sh -lc 'curl -s -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" -d "{\"model\":\"oc/mimo-v2.5-free\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}],\"max_tokens\":32}" http://9router:8080/v1/chat/completions'
```

A reasoning model can spend a small `max_tokens` budget entirely on its reasoning trace and return
`"content": null` with `finish_reason: "length"` — that is still a successful round-trip, not an error. Give
it 32+ tokens to see actual content.

Then recreate Hermes to pick up config changes:

```bash
docker compose up -d --force-recreate hermes
```

Hermes state (skills, memory, gateway config) lives in the `9router_hermes-data` volume, so it survives
recreates the same way 9Router's does.

#### Finding the 9Router API key

The provider entry above needs `NINEROUTER_API_KEY` in `.env`. 9Router auto-creates a **Default Key** on first
start — read it from the dashboard under **Endpoint & Key**, or pull it over the API:

```bash
curl -s -c /tmp/9c -X POST -H 'Content-Type: application/json' -d '{"password":"changeme123"}' http://localhost:8080/api/auth/login >/dev/null && curl -s -b /tmp/9c http://localhost:8080/api/keys | python3 -c 'import json,sys;print(json.load(sys.stdin)["keys"][0]["key"])'; rm -f /tmp/9c
```

---

## 🔎 The model picker: what the counts mean

Hermes' **Switch Model** dialog does not surface routing errors — it silently falls back to whatever it can
resolve. The model *count* next to `9router` is therefore the real diagnostic:

| What you see | Cause | Fix |
|---|---|---|
| `9router · 1 models` | The API key is dead or missing. Hermes cannot list anything, so it shows only the configured `default_model`. | `./generate.sh --up` |
| `9router · N models`, but a model you just added in 9Router is missing (filter says *no models match*) | Stale catalog. Hermes discovers models on demand and caches them for ~1h, so anything added on the 9Router side afterwards is invisible. | **Refresh Models** in the dialog, or `./generate.sh --key-only` |
| `9router · 0 models` | 9Router is unreachable (wrong `base_url`, pod/container down). | Check the endpoint is up and the URL in [`hermes-config.yaml`](hermes-config.yaml) |

The two failure modes look alike but are unrelated: **1 model = auth**, **missing-a-few = cache**. Only the
first is a real fault; the second is expected any time you change 9Router's provider list.

### Adding models on the 9Router side

9Router's Providers page (e.g. **OpenCode Free → Add Model**) changes only 9Router. Hermes keeps serving its
cached list until refreshed, so the new ids will not appear in the picker or match its filter. Refresh after
adding, and confirm the count moved — for example 691 → 696 after adding four `oc/…` models.

List what 9Router actually serves, so you can compare against the picker:

```bash
docker compose exec 9router node -e "fetch('http://127.0.0.1:8080/v1/models').then(r=>r.json()).then(j=>console.log(j.data.length+' models'))"
```

### The current model changed on its own

The picker writes to `config.yaml` — the dialog says *"Saves to config.yaml"*. Switching a model in the UI
therefore overrides the default you set in the seed file, and it persists. If the badge shows something you
did not choose (for example `alicode-intl/qwen3.5-plus` when your default is `oc/mimo-v2.5-free`), switch it
back in the dialog; editing the seed file only affects a fresh install.

---

## 🧪 Testing the API with curl

### 🏠 From inside the container — no key needed

9Router trusts **loopback inside the container**, which is not the same as the host's `localhost`. A request
from the host reaches the container through Docker's NAT and arrives with the bridge gateway as its source
address — so 9Router classifies it as remote and rejects it:

```bash
curl -s http://localhost:8080/v1/models     # -> {"error":"API key required for remote API access"}
```

That is verified behaviour, not a guess: on this stack the host gets `401` while the same request from inside
the container gets `200`. It surprises people because "run it on the server" normally means loopback.

The genuinely keyless check runs the request inside the container:

```bash
docker compose exec 9router node -e "fetch('http://127.0.0.1:8080/v1/models').then(r=>{console.log(r.status);return r.text()}).then(t=>console.log(t.slice(0,200)))"
```

That confirms the container is up and routing before keys or firewalls enter the picture. It costs no provider
tokens — `/v1/models` is served from 9Router's own registry. Everywhere else, including the host shell, needs
a key.

### 🌍 From the host or anywhere else — key required

From the host shell, another machine, or a browser, the same URL returns:

```json
{"error":"API key required for remote API access"}
```

That is 9Router's own gate, not the provider's. You need a key that 9Router **generated** — open the dashboard
at your `PUBLIC_URL`, log in, and create one in the **Endpoints** section.

> `API_KEY_SECRET` is not that key. It is the HMAC secret 9Router signs generated keys *with* — sending it as
> a Bearer token fails exactly like sending nothing, because it is not a key, and `dev-api-key-secret-change-me`
> in particular is only the committed placeholder. The same goes for `JWT_SECRET` and `INITIAL_PASSWORD`:
> secrets the server uses internally, not credentials the API accepts.

With a generated key in hand:

```bash
export NINEROUTER_URL=http://44.198.185.28:8080
```

```bash
export NINEROUTER_API_KEY=<paste-the-key>
```

```bash
curl -s "$NINEROUTER_URL/v1/models" -H "Authorization: Bearer $NINEROUTER_API_KEY" | head -40
```

`jq` makes the model list readable if it is installed:

```bash
curl -s "$NINEROUTER_URL/v1/models" -H "Authorization: Bearer $NINEROUTER_API_KEY" | jq -r '.data[].id'
```

9Router speaks several dialects on the same port, so the Anthropic-style header works too:

```bash
curl -s "$NINEROUTER_URL/v1/models" -H "x-api-key: $NINEROUTER_API_KEY" | head -40
```

To see the status code rather than just the body — useful for telling a key problem (`401`) apart from a
firewall or wrong-port problem (connection refused / timeout):

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$NINEROUTER_URL/v1/models" -H "Authorization: Bearer $NINEROUTER_API_KEY"
```

### 💬 An actual completion

This one **does** spend provider tokens, so keep `max_tokens` small — on a metered lab account it is easy to
burn a quota with a careless smoke test. Use a model id from the `/v1/models` output above:

```bash
curl -s "$NINEROUTER_URL/v1/chat/completions" -H "Authorization: Bearer $NINEROUTER_API_KEY" -H "Content-Type: application/json" -d '{"model":"<model-id-from-v1-models>","messages":[{"role":"user","content":"reply with the single word: ok"}],"max_tokens":5}'
```

A `200` from `/v1/models` already proves the port, the key and the router. Only run the completion when you
specifically need to prove a provider account works end to end.

---

## 🔧 What the file sets, and why

Fixed in the compose file:

| Key | Value | Why |
|---|---|---|
| `PORT` | `8080` | Moves the app off `20128`. This is the difference from the parent guide. |
| `HOSTNAME` | `0.0.0.0` | Bind all interfaces *inside* the container — without it the app may bind loopback only, and the published port would connect to nothing. This is the container's internal bind, not what the host exposes; `BIND_ADDR` controls that. |
| `NODE_ENV` | `production` | What upstream's VPS deployment sets. |
| `DATA_DIR` | `/app/data` | Points the app at the named volume instead of `~/.9router`. |
| `NEXT_PUBLIC_CLOUD_URL` | `https://9router.com` | Upstream's hosted-companion URL. |

### ✏️ Overriding the defaults

These take a default from the compose file and can be overridden in an optional `.env` beside it — copy
[`.env.example`](.env.example) as a starting point. `.env` is gitignored.

| Key | Default | Why |
|---|---|---|
| `INITIAL_PASSWORD` | `changeme123` | Dashboard login password, replacing 9Router's `123456`. See [First start](#-first-start-and-the-default-password) — it only applies to a fresh data volume. |
| `JWT_SECRET` | `dev-jwt-secret-change-me` | Signs dashboard sessions. A fixed value is what keeps you logged in across container recreates. |
| `API_KEY_SECRET` | `dev-api-key-secret-change-me` | Signs the API keys 9Router issues to your agents. |
| `MACHINE_ID_SALT` | `dev-machine-id-salt-change-me` | Salts the derived machine id. |
| `REQUIRE_API_KEY` | empty | `true` enforces a Bearer key on all `/v1/*` routes, including from localhost. Upstream recommends it for internet-exposed deploys. |
| `PUBLIC_URL` | `http://localhost:8080` | Sets `BASE_URL` and `NEXT_PUBLIC_BASE_URL`. The dashboard builds absolute links and OAuth callback URLs from these — if it does not match the URL in your browser, provider logins (Claude Code, Codex, GitHub, Cursor) fail to redirect back while the dashboard itself still loads. Confusing to chase. |
| `BIND_ADDR` | `0.0.0.0` | Host interface the ports are published on. `127.0.0.1` to keep them local-only. |
| `NINEROUTER_API_KEY` | empty | Key the Hermes agent authenticates to 9Router with — see [The Hermes agent service](#-the-hermes-agent-service). Generated in the dashboard's Endpoints section. |
| `HERMES_DASHBOARD_USERNAME` | `admin` | Hermes dashboard login name. |
| `HERMES_DASHBOARD_PASSWORD_HASH` | scrypt of `changeme123` | scrypt hash of the dashboard password. **Setting it empty stops Hermes from starting at all** — see [Hermes dashboard password](#-hermes-dashboard-password). |
| `HERMES_DASHBOARD_SECRET` | `dev-dashboard-session-secret-change-me` | Signs dashboard sessions. Rotating it logs everyone out. |
| `HERMES_API_SERVER_KEY` | `dev-hermes-api-key-change-me` | Bearer token for the Hermes API on 8642. **Empty means the API server never binds**, and the healthcheck fails forever. |
| `HERMES_DASHBOARD_HOST_PORT` | `9119` | **Host** port for the Hermes dashboard, e.g. `8081` to fit an AWS security group. Container side stays 9119. |
| `HERMES_API_HOST_PORT` | `8642` | **Host** port for the Hermes API. Container side stays 8642. |
| `HERMES_API_BIND` | `127.0.0.1` | Interface the Hermes **API** publishes on — loopback regardless of `BIND_ADDR`, because that endpoint runs agent work. Change it only deliberately. |
| `HEADROOM_URL` | empty | Compression off unless you opt in — see [Headroom](#-headroom-optional). |
| `DEBUG` | empty | `true` for verbose logging. |

The three `dev-*-change-me` values are placeholders, not secrets — they are committed to this repo, so anyone
reading it knows them. They exist so `docker compose up -d` works with nothing else in place. Replace them
before the port is reachable by anyone but you:

```bash
printf 'JWT_SECRET=%s\nAPI_KEY_SECRET=%s\nMACHINE_ID_SALT=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 16)" >> .env
```

`PORT: "8080"` is quoted deliberately. Compose rejects non-string environment values, and unquoted port
*mappings* are worse — YAML's sexagesimal rules read `MM:SS`-shaped pairs as a single integer, the classic
case being `22:22` becoming `1342`. Quote both.

The stack is pinned to project name `9router` (top-level `name:`), so volumes are `9router_9router-data`
rather than being named after whatever directory you cloned into.

### 🔀 Changing the port

Change all three places together — `ports`, `PORT`, and `PUBLIC_URL`. Missing one is the usual cause of a
dashboard that loads but cannot complete a login. To publish on a different host port while leaving the app on
8080, change only the left-hand side of the mapping and set `PUBLIC_URL` to match.

---

## 🔓 First start and the default password

9Router ships with password `123456` and refuses remote logins until it is changed:

> Default password must be changed before remote access. Change it from the local machine (or set
> `INITIAL_PASSWORD`).

`INITIAL_PASSWORD` is read when the database is **initialized** — that is, on the first start against an empty
data volume. Adding it to `.env` afterwards does not rewrite a password that already exists, so if you have
already started the stack once you have two options:

**Reset — destroys the database, fine if you have not added providers yet:**

```bash
docker compose down -v && docker compose up -d
```

**Keep the data —** change the password from the dashboard, reaching it over an SSH tunnel so 9Router sees the
connection as local:

```bash
ssh -L 8080:127.0.0.1:8080 user@<vps-ip>
```

Then open <http://localhost:8080> on your laptop and change it in settings. This is also the way in if you
ever lock yourself out remotely.

---

## ☁️ VPS deployment

Upstream documents a bare-metal `git clone` + `npm run build` install; this stack is the container equivalent
and takes the same variables. `docker compose up -d` alone already works and already publishes on `0.0.0.0` —
on a server, set two things beyond that.

Real secrets and a real password:

```bash
printf 'JWT_SECRET=%s\nAPI_KEY_SECRET=%s\nMACHINE_ID_SALT=%s\nINITIAL_PASSWORD=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$(openssl rand -hex 16)" "$(openssl rand -base64 18)" >> .env
```

That appends a generated password too — read it back with `grep INITIAL_PASSWORD .env` and keep it somewhere.

The address the app should think it has, which is the one you type in the browser:

```bash
printf 'PUBLIC_URL=http://%s:8080\n' "$(curl -s https://checkip.amazonaws.com)" >> .env
```

Then start it, recreating the volume so `INITIAL_PASSWORD` is actually applied:

```bash
docker compose down -v && docker compose up -d
```

Leave `PUBLIC_URL` at `localhost` and the dashboard still loads over the public IP, but OAuth callbacks point
back at the server's own loopback and fail.

### 🔢 Fitting an AWS security group

Security groups usually open a small range. If yours allows **8080–8089**, only 8080 is usable out of the box
— the Hermes dashboard's default 9119 falls outside it and will simply time out from the internet, even
though `docker ps` shows it bound to `0.0.0.0`. Move the host port into range:

```bash
printf 'HERMES_DASHBOARD_HOST_PORT=8081\n' >> .env && docker compose up -d hermes
```

| Service | Host port | In an 8080–8089 group |
|---|---|---|
| 9Router dashboard + `/v1` | 8080 | ✅ reachable |
| Hermes dashboard | 8081 (from 9119) | ✅ reachable once remapped |
| Hermes API | 8642, bound to `127.0.0.1` | ⛔ not exposed — **leave it that way** |

Keeping the Hermes API off the range is deliberate rather than an oversight. Hermes itself warns about it on
startup:

> API server is network-accessible (0.0.0.0) AND the terminal backend is 'local' (unsandboxed). Agent work
> dispatched through this endpoint runs as the host user with full terminal/file access.

That is remote code execution as the container user for anyone holding the bearer token — and this stack ships
a *public committed* default token. Reach it through an SSH tunnel instead:

```bash
ssh -L 8642:127.0.0.1:8642 user@<vps-ip>
```

Before exposing it, know what is behind the port: the dashboard holds every provider API key and OAuth token
you add, and it is plain HTTP — the password crosses the network in clear text, as your browser's *Not Secure*
warning says. At minimum restrict the port to your own IP in the cloud firewall or security group:

```bash
aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 8080 --cidr "$(curl -s https://checkip.amazonaws.com)/32"
```

The stronger option is not to publish it at all — set `BIND_ADDR=127.0.0.1` and reach it through the SSH
tunnel above. That costs one command per session and removes the exposure entirely. If it does need to be
genuinely public, put a reverse proxy with TLS in front of it and set `PUBLIC_URL=https://<hostname>`.

---

## 🗜️ Headroom (optional)

[Headroom](https://github.com/chopratejas/headroom) is a local context-compression proxy — 9Router POSTs
outbound messages to its `/v1/compress` endpoint and forwards the compressed result upstream. See
[What is Headroom?](../README.md#what-is-headroom) in the parent guide for what it does and why it helps.

It sits behind a Compose profile, so it does not start unless asked:

```bash
HEADROOM_URL=http://headroom:8787 docker compose --profile headroom up -d
```

Or uncomment it in `.env`, so `docker compose --profile headroom up -d` picks it up on its own:

```
HEADROOM_URL=http://headroom:8787
```

`headroom` is the Compose service name and resolves over the project network — not `localhost`, which inside
the 9Router container means the 9Router container. Enable the integration in the dashboard settings too.

The `headroom-cache` volume holds the compression model downloaded on first run. Without it, every
`docker compose down` throws the download away.

To reach a Headroom you already run on the host instead, drop the profile and use
`HEADROOM_URL=http://host.docker.internal:8787`, adding `extra_hosts: ["host.docker.internal:host-gateway"]`
to the `9router` service on Linux.

---

## 🛠️ Operations

```bash
docker compose logs -f 9router
```

```bash
docker compose ps
```

Stop and start without destroying anything:

```bash
docker compose stop && docker compose start
```

Update to the latest image:

```bash
docker compose pull && docker compose up -d
```

Remove the containers and network, keeping data:

```bash
docker compose down
```

Remove the data too — provider accounts and API keys have to be re-added afterwards:

```bash
docker compose down -v
```

### 💾 Data

State is a SQLite database under `/app/data/db` in the `9router_9router-data` named volume. Named volumes
avoid the UID/GID and fsync problems a bind mount hits with SQLite on Docker Desktop and OrbStack — the
reasoning is in [Why named volumes](../README.md#why-named-volumes).

Inspect it:

```bash
docker compose exec 9router ls -la /app/data/db
```

Back up to a tarball in the current directory, with the container stopped so SQLite is not mid-write:

```bash
docker compose stop 9router && docker run --rm -v 9router_9router-data:/data -v "$PWD:/backup" alpine tar czf /backup/9router-data.tar.gz -C /data . && docker compose start 9router
```

Restore:

```bash
docker compose down && docker run --rm -v 9router_9router-data:/data -v "$PWD:/backup" alpine tar xzf /backup/9router-data.tar.gz -C /data && docker compose up -d
```

---

## 📝 Notes

- `BIND_ADDR` defaults to `0.0.0.0`, so the port is reachable from the network as soon as it starts. The
  dashboard holds provider API keys and OAuth tokens, and 8080 is a port scanners check first — set
  `BIND_ADDR=127.0.0.1` on anything you do not want exposed.
- Keep `.env` out of git. It is gitignored here; the checked-in file is `.env.example`.
- Rotating `JWT_SECRET` invalidates existing dashboard sessions; rotating `API_KEY_SECRET` invalidates the API
  keys your agents are using. Rotate deliberately, not as cleanup.
- One 9Router per host is enough — every agent can share the same `/v1` endpoint.
