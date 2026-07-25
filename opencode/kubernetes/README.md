# ☸️ OpenCode Bridge — Kubernetes Deployment

This directory is a **self-contained Kustomize root** for running the Hermes agent on GKE with **OpenCode's free models** behind it: `kubectl apply -k .` renders and applies the whole stack.

Same concept as [`../../kubernetes`](../../kubernetes) (Hermes + an agent-CLI bridge sidecar, read-only SRE posture, Traefik-fronted dashboard) with a different engine underneath — and **$0 inference**, because the advertised catalogue is restricted to opencode zen models whose input *and* output cost is 0.

```text
Hermes Agent  (gateway + dashboard, container 1)
  → custom Hermes provider "opencode-bridge"  → http://127.0.0.1:18282/v1
      → opencode_bridge.py                    (container 2, loopback only)
          → `opencode run --format json`       (one process per request)
              → opencode zen free models       (MiMo, DeepSeek, Nemotron, Ling, Laguna, …)
```

---

## 🗂️ Directory layout

```text
kubernetes/
├── kustomization.yaml   # the Kustomize root — apply with `kubectl apply -k .`
├── bridge/              # opencode_bridge.py (one copy, mounted read-only)
├── configmaps/          # bridge env + startup, OpenCode permission policy, Hermes runtime
├── rbac/                # ServiceAccount + read-only Role/ClusterRole (the hard backstop)
├── secrets/             # secret.template.yaml (render with envsubst — never apply raw)
├── skills/              # version-controlled Hermes skill, installed declaratively
└── workloads/           # StatefulSet, Service, IngressRoute
```

---

## 🚀 Deploy

```bash
# 0) namespace
kubectl create namespace devops-agent

# 1) secrets — never apply the template raw
export API_SERVER_KEY="$(openssl rand -hex 32)"
export OPENCODE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"
# Hash must come from the SAME Hermes image the StatefulSet runs:
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$(
  docker run --rm nousresearch/hermes-agent:v2026.7.20 \
    /opt/hermes/.venv/bin/python -c \
    'import bcrypt,getpass; print(bcrypt.hashpw(getpass.getpass().encode(),bcrypt.gensalt()).decode())'
)"
envsubst < secrets/secret.template.yaml | kubectl apply -f -

# 2) set your domain once, then apply
#    (edit kustomization.yaml → hermes-params.HERMES_DOMAIN)
kubectl apply -k .

# 3) watch it come up (init containers install OpenCode + kubectl onto the PVC)
kubectl -n devops-agent get pods -w
kubectl -n devops-agent logs -f hermes-agent-0 -c opencode-bridge
```

Nothing else is required. **No model credentials**: opencode zen's free tier works unauthenticated, which is why this deployment has no API-key prerequisite at all.

### Verify

```bash
# The bridge is loopback-only, so probe it from inside the pod:
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- sh -lc '
  curl -fsS -H "Authorization: Bearer $OPENCODE_BRIDGE_API_KEY" http://127.0.0.1:18282/health; echo
  curl -fsS -H "Authorization: Bearer $OPENCODE_BRIDGE_API_KEY" http://127.0.0.1:18282/config'

# What the dashboard model picker will offer (all free):
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- sh -lc '
  curl -fsS -H "Authorization: Bearer $OPENCODE_BRIDGE_API_KEY" http://127.0.0.1:18282/v1/models'

# End-to-end through Hermes:
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes -z "Reply with exactly: end-to-end ok"

# The permission policy actually in force:
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- \
  sh -lc '$OPENCODE_BIN debug config' | head -25
```

---

## 🔒 Security model — four independent layers

The agent is read-only. Each layer holds on its own, so widening one does not open the cluster.

| # | Layer | What it stops | Where |
|---|-------|---------------|-------|
| 1 | **OpenCode permission policy** | `edit`, `write`, `patch` are `deny`, so those tools are **removed from the model's tool list** — it cannot attempt a file mutation. `external_directory: deny` keeps it inside the workspace. | [`configmaps/configmap-opencode-config.yaml`](configmaps/configmap-opencode-config.yaml) |
| 2 | **Read-only `kubectl` wrapper** | Allowlisted verbs only (`get`, `describe`, `logs`, `top`, `events`, `explain`, `api-resources`, `api-versions`, `version`, `cluster-info`, `auth can-i`, `config view`). Everything else exits 77 with a clear message; Secrets are refused outright. It sits earlier on `PATH` than the real binary. Widen it *temporarily* via `KUBECTL_EXTRA_WRITE_VERBS` (empty here — see the [demo overlay](../../opencode-demo)). | `kubectl-ro` in [`configmaps/configmap-opencode-bridge-startup.yaml`](configmaps/configmap-opencode-bridge-startup.yaml) |
| 3 | **RBAC — the hard backstop** | `get/list/watch` only, cluster-wide; **no Secrets anywhere**, no write verbs, no `exec`/`attach`/`port-forward`. Enforced by the API server, so it holds even if layers 1–2 were misconfigured or the model is prompt-injected. | [`rbac/`](rbac) |
| 4 | **Container hardening** | Non-root (`fsGroup: 10000`), `allowPrivilegeEscalation: false`, `NET_RAW`/`NET_ADMIN` dropped, bridge bound to `127.0.0.1` and never exposed via the Service. | [`workloads/statefulset.yaml`](workloads/statefulset.yaml) |

Hermes' own tools are constrained too: `code_execution` is disabled and `security.allow_lazy_installs: false`, so the agent is limited to the binaries baked in by the init containers.

### ⚠️ OpenCode permission semantics — verified, and counter-intuitive

These were established empirically against opencode 1.18.5 and the policy in this repo depends on them:

1. **`deny` removes the tool, it doesn't just refuse the call.** With `edit`/`write`/`patch` denied, the model reports *"I don't have a write tool"* — the capability never reaches it. This is stronger than a runtime refusal.
2. **`ask` + `--auto` == `allow`.** The bridge passes `--auto` so a headless run can't block on a prompt, and `--auto` auto-approves anything not *explicitly* denied. A capability left on the implicit `ask` default is therefore **not** a guardrail. Every permission in the policy is set explicitly for this reason.
3. **A pattern map with a catch-all `deny` removes the tool wholesale.** `bash: {"kubectl get *": "allow", "*": "deny"}` does **not** yield "only kubectl get" — it removes `bash` entirely, allow-patterns included. That is why `bash` is granted flatly here and constrained by the wrapper + RBAC instead, which are enforced outside the model's cooperation.
4. **Load the policy by absolute path.** `OPENCODE_CONFIG=/etc/opencode/opencode.json` is reliable; a project-level `./opencode.json` is only honored when the cwd resolves to a real project root, which a bare mounted workspace does not always satisfy. The startup script logs the resolved config and warns loudly if `write` is not denied.

---

## ⚙️ Configuration

Everything tunable lives in two ConfigMaps — no manifest surgery needed.

[`configmaps/configmap-opencode-bridge-env.yaml`](configmaps/configmap-opencode-bridge-env.yaml):

| Key | Default | Purpose |
|-----|---------|---------|
| `OPENCODE_BRIDGE_MODEL` | `opencode/mimo-v2.5-free` | Default model |
| `OPENCODE_BRIDGE_FREE_ONLY` | `"true"` | Serve only zero-cost models; a mis-typed model can't start spending |
| `OPENCODE_BRIDGE_MODELS` | *(empty = discover)* | Pin the advertised catalogue. Pinning opts **out** of tracking the free tier |
| `OPENCODE_BRIDGE_MODEL_REFRESH_INTERVAL` | `"3600"` | Re-discover the catalogue on this interval so free models opencode zen adds appear — and retired ones disappear — without a restart (`0` disables) |
| `OPENCODE_BRIDGE_MODEL_CACHE` | `/opt/data/opencode-models.json` | Where each successful discovery is persisted. Used as the fallback when discovery fails, and read by `init-hermes-config` to build the dashboard picker |
| `OPENCODE_BRIDGE_AGENT` | `build` | OpenCode agent per request (`build`, `plan`, a custom one) |
| `OPENCODE_BRIDGE_VARIANT` | *(empty)* | Reasoning variant (`minimal`, `high`, `max`) |
| `OPENCODE_BRIDGE_MAX_CONCURRENCY` | `"2"` | Concurrent `opencode run` processes (free tiers rate-limit) |
| `OPENCODE_BRIDGE_TIMEOUT` | `"600"` | Per-request timeout, seconds |
| `OPENCODE_BRIDGE_SHOW_TOOLS` | `"1"` | Inline `› kubectl(…)` progress notes in the transcript |
| `OPENCODE_BRIDGE_SHOW_REASONING` | `"0"` | Include reasoning blocks (noisy) |
| `OPENCODE_BRIDGE_DELETE_SESSIONS` | `"1"` | Delete each run's persisted session so the PVC stays small |
| `OPENCODE_NPM_SPEC` | `opencode-ai@latest` | Pin to freeze the CLI version |
| `KUBECTL_EXTRA_WRITE_VERBS` | `""` **(read-only)** | Space-separated verbs the `kubectl` wrapper accepts *in addition* to the read-only allowlist. The demo overlay in [`../../opencode-demo`](../../opencode-demo) sets `"patch set rollout"`; RBAC still bounds what they can touch |

[`configmaps/configmap-hermes-runtime-env.yaml`](configmaps/configmap-hermes-runtime-env.yaml) holds the images, the dashboard/gateway settings, and the first-run model seed.

> 💡 **Provider id is `opencode-bridge`, not `opencode`.** Hermes ships a built-in OpenCode Zen provider whose canonical id is `opencode-zen` with `opencode` as an alias. A user-declared `providers.opencode` *does* win that resolution (verified with `hermes_cli.runtime_provider._get_named_custom_provider`), but in-cluster there is no reason to rely on alias precedence — the unambiguous name keeps requests on this pod's loopback bridge instead of the cloud endpoint.

### Using paid models instead

1. Seed `OPENCODE_API_KEY` in `hermes-agent-secrets` (the startup script writes OpenCode's `auth.json` from it).
2. Set `OPENCODE_BRIDGE_FREE_ONLY: "false"` and add the provider to `OPENCODE_BRIDGE_MODEL_PROVIDERS`.
3. Re-apply and restart: `kubectl -n devops-agent rollout restart statefulset/hermes-agent`.

---

## 🔄 The model list is discovered, never declared

opencode zen's free tier moves — models get added, and today's free model can stop being free. So no part of this deployment hardcodes a model list:

| Where the catalogue shows up | How it stays current |
|---|---|
| The bridge's `/v1/models` (what Hermes reads) | Re-discovered from `opencode models --verbose --refresh` every `OPENCODE_BRIDGE_MODEL_REFRESH_INTERVAL` (default hourly). Logs `catalogue changed via …: +[…] -[…]` when it shifts |
| Right now, on demand | `POST /v1/models/refresh` — returns the new list plus what was added/removed |
| The **dashboard model picker** (`providers.*.models` in `config.yaml`) | `init-hermes-config` rebuilds it on every boot from the cache the bridge writes — so a new free model lands in the dropdown after the next restart |
| When discovery fails (no egress, models.dev down) | Falls back to `OPENCODE_BRIDGE_MODEL_CACHE` on the PVC — the last catalogue that actually worked, which beats a list frozen in code |
| The default model itself | If it's been retired, the bridge adopts the first available model and logs the substitution instead of advertising something the CLI can no longer run |

```bash
# force a refresh and see what changed
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- sh -lc '
  curl -fsS -X POST -H "Authorization: Bearer $OPENCODE_BRIDGE_API_KEY" \
    http://127.0.0.1:18282/v1/models/refresh'

# what the last discovery found (also feeds the dashboard picker)
kubectl -n devops-agent exec hermes-agent-0 -c opencode-bridge -- \
  cat /opt/data/opencode-models.json
```

The literal lists that remain — `FALLBACK_FREE_MODELS` in the bridge and `SEED_MODELS` in `init-hermes-config.sh` — are only a first-boot seed for a volume the bridge has never run on. They are expected to drift, and nothing depends on them once the cache exists.

## 🧠 What runs where

| Container | Image | Role |
|-----------|-------|------|
| `hermes` | `nousresearch/hermes-agent` | Gateway (`:8642`) + dashboard (`:9119`) |
| `opencode-bridge` | `node:22-bookworm-slim` | npm-installs OpenCode, serves chat-completions on `127.0.0.1:18282` |
| *init* `init-workspace` | `busybox` | Creates + chowns the workspace OpenCode runs in |
| *init* `init-opencode` | `node:22-bookworm-slim` | Pre-installs the CLI onto the PVC so the sidecar starts ready |
| *init* `init-kubectl` | `curlimages/curl` | Installs the **real** kubectl at `/opt/data/kubectl/kubectl` (off `PATH`) |
| *init* `init-hermes-config` | `nousresearch/hermes-agent` | Seeds `config.yaml` with the `opencode-bridge` provider + free-model catalogue |

The CLI installs to versioned directories with an atomically repointed `current` symlink and a daily refresh, keeping the last 3 releases — a bad release is a one-symlink rollback.

**PVC (20Gi)**: OpenCode releases, kubectl, Hermes state, and the workspace. Smaller than the Claude deployment's 50Gi because there's no model cache and each run's session is deleted.

---

## 🧯 Troubleshooting

| Symptom | Fix |
|---------|-----|
| `opencode-bridge` never becomes ready | `kubectl logs hermes-agent-0 -c opencode-bridge` — first boot installs npm packages and resolves the catalogue; the probe allows ~80s (`failureThreshold: 6`) |
| Bridge log warns `opencode policy did not load — write is NOT denied` | The policy ConfigMap isn't mounted where `OPENCODE_CONFIG` points; check the `opencode-config` volumeMount and re-apply |
| `/config` shows `"models_source": "fallback"` | `opencode models --verbose` failed (egress blocked?) — the built-in free list is being used; fix egress and restart |
| Dashboard model dropdown is empty | Hermes reads the provider's `models` map from `config.yaml`; check `init-hermes-config` logs, then `kubectl exec … -c hermes -- cat /opt/data/config.yaml` |
| `400 model … is not available on this bridge` | Free-only mode refused a paid/unknown model — pick one from `/v1/models` or see "Using paid models" |
| `429 bridge busy` | More concurrent chats than `OPENCODE_BRIDGE_MAX_CONCURRENCY`; raise it gently (free tiers rate-limit) |
| `504 opencode command timed out` | Long agentic run — raise `OPENCODE_BRIDGE_TIMEOUT` |
| `kubectl: verb 'x' is blocked` in a transcript | Working as designed (layer 2). The agent is read-only |
| Image/vision requests fail | The free models are text-only — set `HERMES_VISION_BASE_URL` (see `secrets/secret.template.yaml`) to route Hermes' Vision task elsewhere |
| Both this and the Claude stack in one cluster | They share namespace and resource names; deploy one at a time, or change the namespace in every manifest. Cluster-scoped RBAC is already uniquely named (`hermes-opencode-cluster-readonly`) |

---

## ✅ What was validated before commit

Locally, without a cluster (`kubectl kustomize`, `sh -n`, live OpenCode runs):

- `kubectl kustomize .` renders; every built-in resource passes `kubectl apply --dry-run=client` (the `IngressRoute` needs Traefik's CRDs to be installed, which is expected)
- All Kustomize replacements fire: images, `imagePullPolicy`, the bridge `containerPort` (`18282`, as an int), and `HERMES_DOMAIN` fanned out to all three Traefik routes — the domain check was run with a *different* value to prove the substitution rather than assume it
- Every embedded script passes `sh -n`/`bash -n`; the embedded Python in `init-hermes-config.sh` compiles; heredoc terminators verified at column 0 after YAML block-scalar stripping
- The exact `opencode.json` being shipped loads cleanly (`opencode debug config` echoes it back)
- The `kubectl-ro` wrapper was exercised over 15 cases — `get`/`describe`/`logs`/`auth can-i`/`config view` pass through; `delete`/`apply`/`patch`/`exec`/`port-forward`/`auth reconcile`/`config set-context`/`get secret(s)` all exit 77
- `bridge/opencode_bridge.py` passes its offline selfcheck (`BRIDGE_SELFCHECK=1 python3 bridge/opencode_bridge.py`)

And **live on GKE** (`hermes-cluster`, ns `devops-agent`): pod 2/2 with all four init containers clean; policy loaded (`edit`/`write`/`patch` denied per `opencode debug config`); 7 free models discovered; the wrapper passing reads and refusing `delete`/`apply`/`exec`/Secrets; RBAC refusing Secrets and deletes *independently* of the wrapper (called via `$KUBECTL_REAL`); `hermes -z` round-tripping; and an agentic run answering a live cluster question at `cost_usd=0.0`.

> 🐞 The `kubectl-ro` verb parser was fixed after a live run: it read `$1` as the verb, so standard flags-first syntax (`kubectl -n demo get pods`) was wrongly refused. It now skips leading global flags — including value-taking ones and `--flag=value` — and finds `auth can-i` / `config view` sub-verbs the same way. Re-verified over 20 command shapes in both gate states; the failure mode was a false refusal, never a false permit. See [`../../opencode-demo`](../../opencode-demo) for the full write-up.

---

> 🖥️ Want this on your laptop instead of a cluster? See [`../hermes-desktop`](../hermes-desktop). 🤖 Prefer Claude Code as the engine? See [`../../kubernetes`](../../kubernetes) (or [`../../vertex-ai`](../../vertex-ai) for Vertex AI).
