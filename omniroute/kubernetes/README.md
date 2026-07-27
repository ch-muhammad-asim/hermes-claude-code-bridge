# ☸️ OmniRoute — Kubernetes deployment

Self-contained **Kustomize root** for running OmniRoute in a cluster: `kubectl apply -k .` renders and
applies the whole stack.

Verified end-to-end against a real Kubernetes **v1.34** API server — the StatefulSet reaches
`1/1 Running`, the PVC binds, the IngressRoute validates against the Traefik CRDs, and the database
survives a pod delete.

## 🗂️ Layout

```text
kubernetes/
├── kustomization.yaml           # the Kustomize root — kubectl apply -k .
├── generate-secrets.sh          # generates + PRINTS + applies every Secret (start here)
├── namespace.yaml               # namespace: omniroute
├── configmaps/
│   └── configmap-hermes-config.yaml   # init script: registers OmniRoute as Hermes' provider
├── secrets/
│   ├── secret.template.yaml           # OmniRoute secrets — render with envsubst, never apply raw
│   ├── hermes-secret.template.yaml    # Hermes secrets (incl. the OmniRoute client key)
│   └── README.md
├── workloads/
│   ├── statefulset.yaml               # OmniRoute: replicas 1 + PVC (SQLite is single-writer)
│   ├── service.yaml                   # OmniRoute ClusterIP :20128
│   ├── ingressroute.yaml              # OmniRoute Traefik TLS route
│   ├── hermes-statefulset.yaml        # Hermes agent + PVC
│   ├── hermes-service.yaml            # Hermes ClusterIP :8642 (API) / :9119 (dashboard)
│   └── hermes-ingressroute.yaml       # Hermes Traefik TLS route
└── optional/                          # opt-in extras, NOT in kustomization.yaml
    ├── redis.yaml                     # shared rate-limit cache
    └── networkpolicy.yaml             # restrict :20128 to the Hermes pod + ingress
```

## 🤝 What gets deployed: Hermes + OmniRoute

```text
  Slack / dashboard / API
        │
        ▼
   Hermes agent  ──── chat_completions ────▶  OmniRoute :20128/v1
   :8642 · :9119                                     │
                                                     ▼
                            any provider connected in OmniRoute
                            default: oc/deepseek-v4-flash-free (OpenCode Zen, $0)
```

**There is no bridge sidecar here** — unlike the [Claude Code](../../kubernetes) and
[OpenCode](../../opencode) deployments, which wrap a CLI to *create* an OpenAI-compatible endpoint.
OmniRoute already *is* one, so Hermes talks to its ClusterIP Service directly and OmniRoute handles
provider fan-out, fallback and quotas.

### 🎛️ Models: everything OmniRoute offers, unfiltered

`init-hermes-config` seeds Hermes' model picker from OmniRoute's live `/v1/models` with **no
restrictions** (`HERMES_OMNIROUTE_MODEL_ALLOWLIST="*"`, the default). OmniRoute is the router — it owns
which providers are connected, the routing strategy and fallback — so Hermes doesn't second-guess its
catalogue. Verified: **163 models** offered, including 65 `oc/*` ids and paid providers.

The default model is **`oc/deepseek-v4-flash-free`** — an OpenCode Zen free model, $0 inference,
verified answering end-to-end through Hermes' own API (`HTTP 200`, reply `'ok'`).

Narrow it only if you want to:

```yaml
- name: HERMES_OMNIROUTE_MODEL_ALLOWLIST
  value: "oc/deepseek-v4-flash-free,oc/ling-3.0-flash-free"   # or "*" for everything
```

> 🔑 **Whether a model answers depends on OmniRoute's provider connections, not on Hermes.** On a fresh
> install most `oc/*-free` ids return `401 … is not supported`; after connecting **Providers → OpenCode
> Free** in the OmniRoute dashboard they work (verified — `mimo-v2.5-free` answers in OmniRoute's own
> Playground once connected). Two ids answer with *no* connection at all:
> `oc/deepseek-v4-flash-free` and `oc/ling-3.0-flash-free` — which is why they're the offline fallback
> list and the default.
>
> This is also why a model can work in the OpenCode desktop app but 401 through OmniRoute: the app is
> signed into your OpenCode account, OmniRoute needs its own connection.

> 🧠 **The `auto/*:free` combos are not used as the default.** They answer fine over `curl` (routing to
> `big-pickle`) but the Hermes TUI rejects their stream shape with *"Provider returned an empty stream
> with no finish_reason"*. They remain selectable — just not the default.

> 🧠 **These are reasoning models.** OmniRoute streams `reasoning_content` before `content`, so a small
> `max_tokens` (e.g. 32) is consumed entirely by reasoning and returns `finish_reason: length` with empty
> content. Hermes' own budgets are fine; keep this in mind for manual `curl` tests (use 300+).

> 🔒 **The stored model wins over the manifest.** `config.yaml` lives on the PVC and the init script uses
> `setdefault`, so a model chosen in the dashboard survives restarts — which also means editing
> `HERMES_DEFAULT_MODEL` has **no effect on an existing PVC**. To make the manifest authoritative, set
> `HERMES_FORCE_DEFAULT_MODEL=true` and roll:
> ```bash
> kubectl -n omniroute rollout restart statefulset/hermes
> kubectl -n omniroute logs hermes-0 -c init-hermes-config | grep forced
> #   [init-hermes-config] forced default model oc/minimax-m2.5-free -> auto/coding:free
> ```

## ✅ Prerequisites

- A cluster and `kubectl` context (any distribution — verified on v1.34).
- A default **StorageClass** for the `ReadWriteOnce` PVC (GKE: `standard-rwo`).
- **Traefik v3 CRDs** installed, if you want the `IngressRoute`. The chart-pinned install in this repo
  is at [`../../kubernetes/traefik/`](../../kubernetes/traefik). Without the CRDs the apply fails with
  `no matches for kind "IngressRoute"` — either install them or drop that line from
  `kustomization.yaml` and expose the Service yourself.

## 🚀 Deploy

**1 — Set your hostnames.** Two routes, two hosts:

| File | Replace | Serves |
|---|---|---|
| `workloads/ingressroute.yaml` | `omniroute.example.com` | OmniRoute — providers, routing, quotas |
| `workloads/hermes-ingressroute.yaml` | `hermes.example.com` | Hermes — agent chat, sessions, skills |

Also update `BASE_URL` / `NEXT_PUBLIC_BASE_URL` in `workloads/statefulset.yaml` to the OmniRoute host —
they must match the public origin or provider OAuth callbacks redirect to the wrong place.

**2 — Create both Secrets.** Easiest path — the script generates every value (including the scrypt
dashboard hash), **prints a "SAVE THIS" block with the two dashboard passwords**, and applies both
Secrets:

```bash
./generate-secrets.sh                 # generate + print + apply
./generate-secrets.sh --print-only    # just show me the values and the kubectl commands
./generate-secrets.sh -n my-namespace # different namespace
```

```text
╔══════════════════════════════════════════════════════════════════════════════╗
║  SAVE THIS — the passwords below cannot be recovered later                    ║
╚══════════════════════════════════════════════════════════════════════════════╝
  ── OmniRoute dashboard ──   Password : <24-char generated password>
  ── Hermes dashboard ────   Username : admin
                             Password : <24-char generated password>
  HERMES_DASHBOARD_..._PASSWORD_HASH  : scrypt$16384$8$1$…
```

Save those two passwords — the hash is one-way, so they cannot be recovered afterwards. Everything else
in the output is regenerable.

<details>
<summary>Prefer to do it by hand with the templates?</summary>

Neither template is in `kustomization.yaml`, so placeholders can never be applied by accident:

```bash
kubectl create namespace omniroute --dry-run=client -o yaml | kubectl apply -f -

# OmniRoute
export JWT_SECRET="$(openssl rand -base64 48)"
export API_KEY_SECRET="$(openssl rand -hex 32)"
export INITIAL_PASSWORD='<strong password — store it in a password manager>'
envsubst < secrets/secret.template.yaml | kubectl -n omniroute apply -f -

# Hermes — see secrets/hermes-secret.template.yaml for the scrypt hash command
export API_SERVER_KEY="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='<scrypt$... from the Hermes image>'
export OMNIROUTE_CLIENT_API_KEY='<mint later in the OmniRoute dashboard>'
envsubst < secrets/hermes-secret.template.yaml | kubectl -n omniroute apply -f -
```

</details>

> ⚠️ **Create the Secrets before `apply -k .`** — otherwise both pods sit in
> `CreateContainerConfigError` with `secret "omniroute-secrets" not found`. They recover on their own
> once the Secrets exist; no re-apply needed.

**3 — Apply the stack and wait** (both StatefulSets):

```bash
kubectl apply -k .
kubectl -n omniroute rollout status statefulset/omniroute --timeout=300s
kubectl -n omniroute rollout status statefulset/hermes --timeout=300s
kubectl -n omniroute get pod,pvc,svc,ingressroute
```

**4 — Connect a provider and give Hermes its key.** In the OmniRoute dashboard: add the
**Providers → OpenCode Go** connection (this is what makes the free models callable), then
**Settings → API Keys** → create a key and hand it to Hermes:

```bash
kubectl -n omniroute patch secret hermes-secrets --type merge \
  -p '{"stringData":{"OMNIROUTE_CLIENT_API_KEY":"<the key>"}}'
kubectl -n omniroute rollout restart statefulset/hermes    # re-runs init, re-discovers models
```

## 🔎 Verify

```bash
# Pod ready and PVC bound
kubectl -n omniroute get pod omniroute-0 -o wide
kubectl -n omniroute get pvc data-omniroute-0        # -> Bound, 10Gi, RWO

# Health through the Service (the probes use this same path)
kubectl -n omniroute port-forward svc/omniroute 20128:20128 &
curl -fsS http://127.0.0.1:20128/api/monitoring/health
#   {"status":"healthy","version":"3.8.48",...}

# The API requires a key here (see below) — 401 without one is CORRECT
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:20128/v1/models    # -> 401
```

Then browse to your `Host()` from the IngressRoute and log in with `INITIAL_PASSWORD`.

### Verify the Hermes ↔ OmniRoute integration

```bash
# Hermes is up
kubectl -n omniroute get pod hermes-0                       # -> 1/1 Running

# The init container registered OmniRoute as the provider
kubectl -n omniroute exec hermes-0 -c hermes -- \
  /opt/hermes/.venv/bin/python -c "import yaml;d=yaml.safe_load(open('/opt/data/config.yaml'));print(d['model'])"
#   {'default': 'oc/minimax-m2.5-free', 'provider': 'omniroute',
#    'base_url': 'http://omniroute:20128/v1', 'api_mode': 'chat_completions', ...}

# Model discovery result (live count, or the fallback list)
kubectl -n omniroute logs hermes-0 -c init-hermes-config | grep init-hermes-config
#   [init-hermes-config] discovered 9 model(s) from OmniRoute
#   [init-hermes-config] provider=omniroute default_model=oc/minimax-m2.5-free models=9

# Hermes can actually reach OmniRoute over the cluster network
kubectl -n omniroute exec hermes-0 -c hermes -- \
  curl -sS -o /dev/null -w 'omniroute health: %{http_code}\n' http://omniroute:20128/api/monitoring/health
#   omniroute health: 200
```

## 🔐 Security posture

| Control | Setting | Why |
|---|---|---|
| **API auth** | `REQUIRE_API_KEY=true` | Upstream defaults this to `false`. In a cluster the Service is reachable by any pod, so an unauthenticated `/v1` would let anything spend your provider quota. Mint keys in **Settings → API Keys** and send `Authorization: Bearer <key>`. |
| **Non-root** | `runAsUser/Group: 1000`, `runAsNonRoot: true` | Matches the image's own `node` user (verified uid/gid 1000). |
| **PVC writable** | `fsGroup: 1000` | Without it the non-root process cannot write `/app/data`. |
| **Capabilities** | `drop: ["ALL"]`, no privilege escalation, `RuntimeDefault` seccomp | Nothing in the workload needs them. |
| **Secure cookies** | `AUTH_COOKIE_SECURE=true` | Valid because traffic is TLS-terminated at Traefik. Set `false` only if you serve plain HTTP, or logins silently fail. |
| **Secrets** | `Secret` + `envFrom`, template excluded from Kustomize | No credentials in Git; the template holds `${...}` only. |

Provider credentials are **not** in these manifests — they are added at runtime in the dashboard and
stored encrypted in OmniRoute's own SQLite database.

## 🗄️ State: why a StatefulSet, not a Deployment

All state is one **SQLite database in WAL mode** on the PVC (verified:
`/app/data/storage.sqlite` + `-wal` + `-shm`). SQLite permits exactly **one writer**, so:

- **`replicas: 1` — never scale this up.** Two pods on one database file risks corruption.
- A **StatefulSet with `volumeClaimTemplates`** gives stable identity and one `ReadWriteOnce` volume,
  instead of a Deployment rollout briefly running two pods against the same file.
- **`terminationGracePeriodSeconds: 40`** lets SQLite checkpoint the WAL on shutdown.
- Verified: `kubectl delete pod omniroute-0` → the pod returns and the database is intact.

Need HA? That is an upstream architectural change (external database), not a replica-count change.

## 🩺 Probes

All three probes hit **`/api/monitoring/health`**, which is unauthenticated (so probes work even with
`REQUIRE_API_KEY=true`) and is exactly what the image's own healthcheck probes.

```yaml
startupProbe:   periodSeconds: 5,  failureThreshold: 30   # absorbs the ~15-25s boot
readinessProbe: periodSeconds: 10
livenessProbe:  periodSeconds: 30, failureThreshold: 3
```

> ⚠️ Do **not** point probes at `/health` or `/api/v1/health` — both **404** on this version, so the pod
> would be killed in a restart loop.

## 📊 Resources

Sized from measurement, not guesswork: idle usage is ~510 MiB RSS against the default 1024 MB Node heap
ceiling (`OMNIROUTE_MEMORY_MB`).

```yaml
requests: { cpu: 250m, memory: 768Mi }
limits:   { cpu: "2",  memory: 2Gi }
```

If you raise `OMNIROUTE_MEMORY_MB`, raise the memory limit above it — otherwise the kernel OOM-kills the
container before Node's own heap limit engages.

## ⚡ Optional Redis

Only needed for shared rate-limit state. With `REDIS_URL` unset, OmniRoute logs
`REDIS_URL is not set in production. Using in-memory rate limiting.` — correct for a single replica, so
**Redis is genuinely optional**.

[`optional/redis.yaml`](optional/redis.yaml) ships it as an opt-in component, deliberately *not*
referenced by `kustomization.yaml` (the Kustomize equivalent of the Compose `--profile redis`):

```bash
kubectl -n omniroute apply -f optional/redis.yaml

kubectl -n omniroute patch secret omniroute-secrets --type merge \
  -p '{"stringData":{"REDIS_URL":"redis://redis.omniroute.svc.cluster.local:6379"}}'

kubectl -n omniroute rollout restart statefulset/omniroute

# confirm OmniRoute picked it up — 0 means the in-memory notice is gone
kubectl -n omniroute logs omniroute-0 | grep -c "REDIS_URL is not set"
```

It is a **Deployment with `emptyDir`**, not a StatefulSet with a PVC: rate-limit counters are a transient
cache, so RDB/AOF persistence is disabled and a `192mb` `allkeys-lru` cap keeps memory bounded (the pod
limit sits above it so eviction engages before an OOM kill).

Verified in-cluster: `redis-cli ping` → `PONG`, the pod resolves
`redis.omniroute.svc.cluster.local`, and after the patch + restart the in-memory notice disappears.
Also verified that if `REDIS_URL` is set but Redis is **unreachable**, OmniRoute still boots and stays
healthy — it degrades instead of crashing, so no `initContainer` or ordering dance is needed.

## 🔄 Upgrades and rollback

```bash
# bump the pinned tag (never deploy `latest` — it is mutable)
sed -i '' 's#omniroute:3.8.48#omniroute:<new-tag>#' workloads/statefulset.yaml
kubectl apply -k . && kubectl -n omniroute rollout status statefulset/omniroute --timeout=300s

# rollback: the PVC persists across image changes, so reverting the tag restores the old binary
kubectl -n omniroute rollout undo statefulset/omniroute
```

Snapshot the PVC before a major upgrade — migrations run automatically on boot and are not reversed by
rolling the image back.

## 🧹 Teardown

```bash
kubectl -n omniroute delete -f optional/redis.yaml --ignore-not-found   # only if you applied it
kubectl delete -k . --ignore-not-found                                  # -k takes the DIRECTORY
```

> 🛑 **`-k .`, not `-f kustomization.yaml`.** `kubectl … -f kustomization.yaml` fails with
> *`no matches for kind "Kustomization"`* (it is a client-side build directive, never sent to the API
> server) and `-k kustomization.yaml` fails with *`must build at directory`*. Add
> `--ignore-not-found` to keep the output quiet when objects are already gone.

Two things `delete -k .` deliberately leaves behind:

| Left behind | Why | Remove with |
|---|---|---|
| `secret/omniroute-secrets` | Not managed by Kustomize — the template is excluded so placeholders can't be applied | `kubectl -n omniroute delete secret omniroute-secrets` |
| `pvc/data-omniroute-0` | Kubernetes retains `volumeClaimTemplates` PVCs on purpose, so deleting the StatefulSet never destroys your database | `kubectl -n omniroute delete pvc data-omniroute-0` ⚠️ **irreversible** |

Deleting the namespace is the one-liner that takes everything — Secret and PVC included:

```bash
kubectl delete namespace omniroute      # ⚠️ destroys the SQLite database with it
```

Confirm nothing is orphaned (a leftover PV keeps consuming disk):

```bash
kubectl get all,pvc,secret -A | grep -i omniroute    # expect no output
kubectl get pv                                        # expect no omniroute-bound volumes
```

## 🩹 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "IngressRoute"` | Traefik CRDs missing — install [`../../kubernetes/traefik/`](../../kubernetes/traefik) or remove that resource. |
| `no matches for kind "Kustomization"` | You used `-f kustomization.yaml`. Kustomize needs `-k` on the **directory**: `kubectl apply -k .` (and `must build at directory` means you passed `-k` a file). |
| **Hermes** `CrashLoopBackOff` with `preinit: fatal: /run belongs to uid 0 instead of 10000` | Something forced the pod non-root. The Hermes image is s6-overlay based: it **must** start as root to fix `/run`, then drops to uid 10000 itself. Use `fsGroup: 10000` **only** — no `runAsUser` / `runAsNonRoot` — and don't `drop: ["ALL"]` (that strips the `SETUID`/`SETGID` s6 needs). Both are already correct in `hermes-statefulset.yaml`. |
| Hermes model calls fail `401 … is not supported` | OmniRoute has no provider **connection** yet. Add **Providers → OpenCode Go** in the OmniRoute dashboard. |
| Hermes logs `model discovery failed (HTTP Error 401)` | `OMNIROUTE_CLIENT_API_KEY` is missing/stale. Hermes still starts on the built-in free-model fallback list; patch the key and restart to get live discovery. |
| A model in the picker fails with `401 … is not supported` | OmniRoute has no connection for that provider. Add it in the OmniRoute dashboard → **Providers**. The picker is unfiltered by design, so it lists ids OmniRoute advertises regardless of connection state. |
| Pod `CreateContainerConfigError` | `omniroute-secrets` doesn't exist yet. Create the Secret (step 2), then the pod recovers on its own. |
| `CrashLoopBackOff`, permission denied on `/app/data` | `fsGroup: 1000` missing or overridden by a policy. |
| Pod killed during startup | Probes pointed at the wrong path, or `startupProbe` too tight. Keep `/api/monitoring/health`. |
| PVC `Pending` | No default StorageClass — set `storageClassName` in `volumeClaimTemplates`. |
| `/v1/*` returns 401 | Expected: `REQUIRE_API_KEY=true`. Create a key in the dashboard and send `Authorization: Bearer <key>`. |
| Dashboard login rejected | `INITIAL_PASSWORD` seeds only the **first** boot against an empty database. |
| OAuth callback hits the wrong host | `BASE_URL` / `NEXT_PUBLIC_BASE_URL` must equal your public origin. |
