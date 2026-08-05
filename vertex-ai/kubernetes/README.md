# ☸️ Vertex AI Gemini — Kubernetes Deployment

This directory is the **self-contained Kustomize root** for the production Hermes + Vertex Gemini
deployment: `kubectl apply -k .` renders and applies the whole stack.

Target production environment:

```text
GCP project: your-gcp-project-id
Vertex location: global
Gemini model: gemini-3.5-flash
```

## 🗂️ Directory layout

```text
kubernetes/
├── kustomization.yaml        # the Kustomize root — apply with `kubectl apply -k .`
├── bridge/                   # vertex_gemini_bridge.py + requirements (+ local-dev README)
├── gcp-mcp/                  # loopback OAuth bridge for the read-only GCP MCP servers
├── github-cli/               # read-only `gh` wrapper (fresh App token per call)
├── identity/                 # SOUL.md — the agent's always-loaded identity
├── skills/                   # version-controlled Hermes skills (declaratively installed)
├── rbac/                     # ServiceAccount
├── secrets/                  # secret.template.yaml (render with envsubst — never apply raw)
└── workloads/                # StatefulSet, Service, IngressRoute
```

## 🏗️ Intended Architecture

```text
Hermes Agent
  -> custom Hermes provider
  -> vertex-gemini-bridge
  -> Google Vertex AI Anthropic partner model endpoint
  -> gemini-3.5-flash
```

The bridge code lives in [`bridge/vertex_gemini_bridge.py`](bridge/vertex_gemini_bridge.py) — a
single copy inside this Kustomize root (no duplicate source tree, no load-restrictor overrides).

Create the `devops-agent` namespace idempotently during the apply flow.

## ✅ Runtime Requirements

- `gemini-3.5-flash` is enabled in Vertex AI Model Garden for `your-gcp-project-id`.
- The GKE cluster has **Workload Identity** enabled (`--workload-pool=<project>.svc.id.goog`) — the
  repo's `gcp/` provisioning does this.
- The pod uses the Kubernetes `ServiceAccount` `hermes-agent` (`rbac/serviceaccount.yaml`), bound via
  the `iam.gke.io/gcp-service-account` annotation to the `hermes-vertex` Google service account —
  see **Workload Identity (Vertex AI)** below for the one-time IAM setup.
- Google API authentication is keyless: ADC resolves short-lived credentials from the GKE metadata
  server. No Google service account JSON key is stored in Kubernetes or Git.
- The bridge runs as a sidecar in the Hermes pod and is exposed only through an internal `ClusterIP`.
- Hermes is configured to use the bridge as a custom Hermes provider.
- GitHub access is the read-only `gh` CLI installed in-pod, not an MCP server. Live-app diagnosis uses the in-cluster **`playwright`** MCP server (headless Chromium) configured by the `init-hermes-config` script; see the Playwright MCP section below. Slack is the native Hermes bot integration (home channel + pairing), not a data MCP.

## ⚙️ Environment Variables

There are **two disjoint sets** of variables here, and conflating them is the most common
deployment error:

| Class | Where it lives | Who sets it | Committed to Git? |
| --- | --- | --- | --- |
| **A. Deploy-time shell variables** | Your terminal, for the length of one deploy | You, via `export` | No — values are per-environment |
| **B. Runtime container variables** | `env:` in `workloads/statefulset.yaml` | The manifest, already | Yes — non-secret values only |

**You only ever export Class A.** Class B is already declared in the StatefulSet; exporting those in
your shell has no effect on the pod and misleads the next operator. The single exception is
`VERTEX_GEMINI_BRIDGE_API_KEY`, which appears in both classes — you export it to *create the Secret*,
and the container receives it back from that Secret.

### A. Deploy-time shell variables (export these)

**A1 — Targeting.** Required by every command in the Apply Flow:

| Variable | Example | Notes |
| --- | --- | --- |
| `PROJECT_ID` | `my-gcp-project` | `gcloud config get-value project` if already set |
| `PROJECT_NUMBER` | `830787271677` | **Derive, never type** — see below. Feeds the WI binding and the SA annotation |
| `CLUSTER_NAME` | `gke-cluster` | Must match the provisioned cluster exactly |
| `ZONE` *or* `REGION` | `us-central1-a` / `us-west1` | **Pick the one matching your cluster.** A zonal cluster queried with `--region` returns `NOT_FOUND` |
| `NAMESPACE` | `devops-agent` | Hardcoded in every manifest **and inside the WI principal string** — changing it requires redoing the IAM binding |
| `KSA_NAME` | `hermes-agent` | Same constraint as `NAMESPACE` |
| `GSA_EMAIL` | `${PROJECT_NUMBER}-compute@developer.gserviceaccount.com` | Derived; see **Workload Identity** for the dedicated-GSA alternative |
| `KUBECONFIG` | `$HOME/.kube/clusters/prod` | Optional but recommended — pins the target cluster instead of trusting the ambient context |

Derive rather than hardcode, so a rebuilt project can't silently point you at the old one:

```bash
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export GSA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
```

**A2 — Secret material.** Consumed only by the `kubectl create secret` / `envsubst` step:

| Variable | How to produce it | Rotation impact |
| --- | --- | --- |
| `API_SERVER_KEY` | `openssl rand -hex 32` | Bearer token for Hermes' own API on `:8642` |
| `VERTEX_GEMINI_BRIDGE_API_KEY` | `openssl rand -hex 32` | Bearer token Hermes uses to reach the bridge on `:18182`. Rotating it requires a pod roll — it is injected into **three** containers |
| `HERMES_DASHBOARD_PASSWORD` | Chosen or `openssl rand -hex 16` | **Plaintext, never reaches the cluster.** Only its hash is stored — persist the plaintext to your secret manager *before* hashing, or it is unrecoverable |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | Derived — see the hashgen step | `scrypt`, one-way. Losing the plaintext means rotating, not recovering |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -hex 32` | Dashboard session-signing key. Rotating invalidates all live sessions |
| `HERMES_IMAGE` | `nousresearch/hermes-agent:v2026.8.3` | Must equal the tag in `workloads/statefulset.yaml`, or the hash is generated by a different build than the one verifying it |

> **`HERMES_DASHBOARD_PASSWORD` is the one that bites.** It exists only in your shell. Write it to your
> secret manager in the same step that generates it — after the shell exits, the cluster holds only an
> scrypt hash and no one can read the password back out.

**A3 — Not exported by you.** `KUBECTL_STABLE_URL`, `KUBECTL_DEST`, `GH_RELEASES_API`, `GH_DEST` appear
as `$VAR` inside the init-container scripts. They are declared in the StatefulSet's own `env:` block and
resolved by the container's shell — exporting them locally does nothing.

### B. Runtime container variables (already in the manifest — do not export)

The `vertex-gemini-bridge` sidecar:

| Variable | Value | Why |
| --- | --- | --- |
| `CLOUD_ML_REGION` | `global` | **Load-bearing.** Gemini 3.x resolves *only* at the global endpoint; regional values return `404 model not found` |
| `GEMINI_MODEL` | `gemini-3.5-flash` | Bridge default is the same |
| `VERTEX_GEMINI_MAX_TOKENS` | `8192` | Output cap |
| `VERTEX_GEMINI_TIMEOUT_SECONDS` | `300` | Per-request timeout |
| `VERTEX_GEMINI_MAX_RETRIES` | `2` | Absorbs transient Vertex 429/5xx so they don't surface as 502s |
| `VERTEX_GEMINI_BRIDGE_API_KEY` | from `hermes-agent-secrets` | Injected via `envFrom`; enables auth (`auth=on`) |

**No project ID is set, deliberately.** `google.auth.default()` resolves the project from the GKE
metadata server via Workload Identity, so the manifests stay project-agnostic. Set
`VERTEX_GEMINI_PROJECT_ID` **only** to bill a project other than the cluster's own.

The bridge also honours these, unset by default: `VERTEX_GEMINI_BRIDGE_HOST` (`0.0.0.0`),
`VERTEX_GEMINI_BRIDGE_PORT` (`18182`), `VERTEX_GEMINI_LOCATION` and `VERTEX_GEMINI_MODEL` (aliases for
`CLOUD_ML_REGION` / `GEMINI_MODEL`), `VERTEX_GEMINI_MAX_PROMPT_CHARS` (`200000`), `VERTEX_GEMINI_DROP_KEYS`,
and `GOOGLE_CLOUD_PROJECT` / `GCP_PROJECT_ID` as project aliases.

> ⚠️ **`ANTHROPIC_VERTEX_PROJECT_ID` does nothing on this deployment.** It is read only by the legacy
> `bridge/vertex_claude_bridge.py` (Anthropic path). The Gemini bridge ignores it — setting it produces a
> silent no-op, not an error.

The `hermes` container additionally fixes `HERMES_HOME=/opt/data`, `HERMES_SKILLS_DIR`,
`HERMES_MEMORY_DIR`, `API_SERVER_*`, `HERMES_DASHBOARD_*`, `SLACK_HOME_CHANNEL*`, and pins
`HERMES_TUI_PROVIDER` / `HERMES_INFERENCE_PROVIDER` to `vertex-gemini-bridge`. Change these in the
manifest, not in a shell.

### Preflight — one block, before you deploy

Paste this after exporting A1 + A2. It fails loudly on anything missing, instead of letting
`envsubst` render an empty string into a Secret:

```bash
: "${PROJECT_ID:?export PROJECT_ID}"        ; : "${PROJECT_NUMBER:?derive PROJECT_NUMBER}"
: "${CLUSTER_NAME:?export CLUSTER_NAME}"    ; : "${NAMESPACE:?export NAMESPACE}"
: "${KSA_NAME:?export KSA_NAME}"            ; : "${GSA_EMAIL:?derive GSA_EMAIL}"
: "${API_SERVER_KEY:?openssl rand -hex 32}"
: "${VERTEX_GEMINI_BRIDGE_API_KEY:?openssl rand -hex 32}"
: "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:?run the hashgen step}"
: "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:?openssl rand -hex 32}"
echo "preflight ok: ${PROJECT_ID} (${PROJECT_NUMBER}) -> ${CLUSTER_NAME}/${NAMESPACE}"
```

An empty `${VAR}` is the failure mode worth guarding: `envsubst` substitutes it happily, the Secret is
created with a blank value, the pod starts, and the bridge comes up with `auth=off` — an unauthenticated
model endpoint inside the cluster. The bridge only enforces the bearer token when the key is non-empty.

### Verifying what the pod actually received

Trust the running container over your shell history:

```bash
# Bridge config as resolved at startup (project came from Workload Identity)
kubectl -n "$NAMESPACE" logs hermes-agent-0 -c vertex-gemini-bridge | grep listening
# -> listening on 0.0.0.0:18182 project=<project> location=global model=gemini-3.5-flash auth=on

# Non-secret env actually present in the sidecar
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-gemini-bridge -- \
  sh -lc 'env | grep -E "^(CLOUD_ML_REGION|GEMINI_MODEL|VERTEX_GEMINI_(MAX|TIMEOUT))" | sort'

# Secret keys present, and their lengths — names and sizes only, never values.
# A length of 0 is the empty-value failure described above.
kubectl -n "$NAMESPACE" get secret hermes-agent-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}={{len $v}}{{"\n"}}{{end}}'
```

`auth=on` in that first line is the check that matters. The bridge treats an empty key as "no auth
configured" and returns `True` from its authorization check unconditionally
([`vertex_gemini_bridge.py`](bridge/vertex_gemini_bridge.py) — `_authorized()`), so `auth=off` is not a
warning to triage later: it means every pod in the cluster can reach the model endpoint unauthenticated.

## 🔌 Hermes Provider Config

Hermes should point to the bridge using a custom Hermes provider:

```yaml
model:
  default: gemini-3.5-flash
  provider: vertex-gemini-bridge
  base_url: http://127.0.0.1:18182/v1
  api_mode: chat_completions

providers:
  vertex-gemini-bridge:
    name: Vertex Gemini Bridge
    base_url: http://127.0.0.1:18182/v1
    api_key: ${VERTEX_GEMINI_BRIDGE_API_KEY}
    default_model: gemini-3.5-flash
    transport: chat_completions

tools:
  tool_search:
    enabled: false
```

For the Vertex provider path, `tool_search` is disabled so Opus 4.8 receives explicit tool definitions
from Hermes directly when tools are enabled.

## 📦 Manifest Files

```text
kustomization.yaml
rbac/serviceaccount.yaml
secrets/secret.template.yaml
workloads/service.yaml
workloads/statefulset.yaml
workloads/ingressroute.yaml
```

The `hermes-agent` ServiceAccount is declared locally in `rbac/serviceaccount.yaml`, so the Vertex manifest set can be applied without depending on the main Kubernetes deployment tree.

`secrets/secret.template.yaml` is an environment-variable template. Do **not** run `kubectl apply -f` on it directly; Kubernetes would accept literal `${...}` placeholders as strings, but the deployment would get invalid secret values. Export every required variable first, then render it:

```bash
envsubst < secrets/secret.template.yaml | kubectl apply -f -
```

`kustomization.yaml` generates the runtime ConfigMaps from Git-owned files in this directory:

```text
hermes-agent-vertex-bridge        -> bridge/vertex_gemini_bridge.py + bridge/requirements.txt
hermes-agent-gcp-mcp-auth-bridge  -> gcp-mcp/gcp_mcp_auth_bridge.py
hermes-agent-github-cli           -> github-cli/gh
hermes-agent-runtime-identity     -> identity/SOUL.md
hermes-agent-declarative-skills   -> skills/lead-devops-sre/SKILL.md
```

These ConfigMaps are only the Kubernetes delivery mechanism for Git-owned text files. They must never
contain credentials, tokens, kubeconfigs, customer data, or mutable runtime state. Secrets remain in
`hermes-agent-secrets` and `hermes-agent-google-oauth`; persistent Hermes state and skills remain on
the PVC under `/opt/data`.

The manifest set is fully self-contained under this directory, so a plain `kubectl apply -k .` works —
no `--load-restrictor` override is needed.

## 🚀 Apply Flow

Authenticate to the production GKE cluster. Every variable below is defined in
**[Environment Variables → A1](#a-deploy-time-shell-variables-export-these)** — that section is the
source of truth; this is the minimum subset to reach the cluster.

Use `--region` only for a regional cluster; a zonal cluster needs `--zone` (see A1).

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-west1"
export CLUSTER_NAME="your-gke-cluster"
export NAMESPACE="devops-agent"

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID"

kubectl config current-context
kubectl top nodes
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

## 🔑 Workload Identity (Vertex AI)

One-time IAM setup binding the `hermes-agent` Kubernetes ServiceAccount to a Google service account
with exactly the permission needed to invoke Vertex AI models — keyless, short-lived credentials from
the GKE metadata server (requires Workload Identity on the cluster, which `gcp/` provisioning enables):

```bash
export PROJECT_ID="your-gcp-project-id"
export NAMESPACE="devops-agent"
export KSA_NAME="hermes-agent"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# Which GSA does the pod act as?
#
#   Outside a sandbox — a dedicated, least-privilege GSA (preferred):
#     export GSA_EMAIL="hermes-vertex@${PROJECT_ID}.iam.gserviceaccount.com"
#     gcloud iam service-accounts create hermes-vertex --project "$PROJECT_ID" \
#       --display-name "Hermes Vertex AI bridge (Workload Identity)"
#     gcloud projects add-iam-policy-binding "$PROJECT_ID" \
#       --member "serviceAccount:${GSA_EMAIL}" --role "roles/aiplatform.user"
#
#   Inside a Pluralsight/ACG sandbox — project-level setIamPolicy is DENIED, so a
#   dedicated GSA can never be granted roles/aiplatform.user and its token 403s on
#   aiplatform.endpoints.predict. Use the Compute Engine default SA, which already
#   carries roles/editor (Vertex included). No role grant needed.
export GSA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Bind the KSA -> GSA (this is SA-level IAM, permitted in the sandbox)
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --role "roles/iam.workloadIdentityUser"

# Annotate the KSA so GKE knows which GSA to mint tokens for
kubectl -n "$NAMESPACE" annotate serviceaccount "$KSA_NAME" \
  "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite
```

**Order matters.** Run the binding *after* the Workload-Identity-enabled cluster exists. The
`<project>.svc.id.goog` identity pool is created by GKE, not by IAM, so binding first fails with:

```text
INVALID_ARGUMENT: Identity Pool does not exist (<project>.svc.id.goog)
```

The KSA-side annotation (`iam.gke.io/gcp-service-account: …`) is already declared in
`rbac/serviceaccount.yaml` and applied by the Kustomize flow below. Verify from the pod after deploy —
ADC should resolve to the GSA via the metadata server:

```bash
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-gemini-bridge -- \
  python3 -c 'import google.auth; c, p = google.auth.default(); print("project:", p)'
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-gemini-bridge -- \
  python3 -c "import urllib.request; r = urllib.request.Request('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email', headers={'Metadata-Flavor': 'Google'}); print(urllib.request.urlopen(r, timeout=3).read().decode())"
# expected: the $GSA_EMAIL bound above
```

Create the bridge API key secret:

```bash
export VERTEX_GEMINI_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_IMAGE='nousresearch/hermes-agent:v2026.8.3'
export HERMES_DASHBOARD_PASSWORD="<value-from-approved-production-secret-manager>"

export HERMES_DASHBOARD_PASSWORD_HASH="$(
  docker run --rm \
    --entrypoint /opt/hermes/.venv/bin/python \
    -e PYTHONPATH=/opt/hermes \
    -e HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
    "$HERMES_IMAGE" \
    -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))'
)"

kubectl -n "$NAMESPACE" create secret generic hermes-agent-secrets \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HERMES_DASHBOARD_PASSWORD_HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=VERTEX_GEMINI_BRIDGE_API_KEY="$VERTEX_GEMINI_BRIDGE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Apply manifests:

```bash
cd vertex-ai/kubernetes
kubectl apply -k .
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=300s
kubectl -n "$NAMESPACE" get statefulset,pod,pvc,svc,ingressroute -o wide
```

## ⬆️ Updating the Hermes Agent Image

The Hermes runtime image is `nousresearch/hermes-agent`, pinned by tag in `workloads/statefulset.yaml`. It is
referenced in **three** places that must stay in sync: the `init-runtime-tools` init container, the
`init-hermes-config` init container, and the `hermes` container. (The `vertex-gemini-bridge` and
`gcp-mcp-auth-bridge` sidecars run `python:3.13-slim` and are unaffected.)

Always pin a dated `vYYYY.M.D` tag. Do **not** deploy `latest` or `main` — they are mutable and not
reproducible.

### 🔍 1. Check for a newer release

```bash
curl -fsS "https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/?page_size=25&ordering=last_updated" \
  | jq -r '.results[] | "\(.last_updated)  \(.name)"' | sort -r
```

Use the newest dated tag. Review the upstream release notes before bumping — a new image can change
Hermes' `config.yaml` schema, which the `init-hermes-config` script merges into; if the schema changed,
update that script's Python block to match.

### ✏️ 2. Bump the tag (all three references)

```bash
cd vertex-ai/kubernetes
OLD=v2026.8.3; NEW=<new-dated-tag>
sed -i '' "s#nousresearch/hermes-agent:${OLD}#nousresearch/hermes-agent:${NEW}#g" workloads/statefulset.yaml
grep -n 'nousresearch/hermes-agent:' workloads/statefulset.yaml   # expect exactly 3 matching lines
```

### 🚀 3. Apply, roll, verify

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod
kubectl apply -k .
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=300s

# confirm the running image and pod health
kubectl -n devops-agent get pod hermes-agent-0 \
  -o jsonpath='{.spec.containers[?(@.name=="hermes")].image}{"\n"}{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}={.ready}{"\n"}{end}'

# smoke-test the runtime: MCP servers load, a chat completion works, gh is read-only
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- /opt/hermes/.venv/bin/hermes mcp list
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- bash -lc 'gh api /rate_limit --jq .resources.core.limit'
```

Then confirm `#devops` answers a read-only prompt, and commit the tag bump to `main`.

### ⏪ 4. Rollback

The PVC (`/opt/data`: config, skills, memory) persists across image changes, so reverting the tag
restores the prior binary without losing state:

```bash
sed -i '' "s#nousresearch/hermes-agent:${NEW}#nousresearch/hermes-agent:${OLD}#g" workloads/statefulset.yaml
kubectl apply -k .
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=300s
```

If a new image rewrote `config.yaml` incompatibly, restore that file from a backup before rolling back.

## 🪪 Runtime Identity (SOUL.md)

`identity/SOUL.md` is the agent's **identity / persona** — the always-loaded system context that defines
who "Hermes SRE" is. It ships as the `hermes-agent-runtime-identity` ConfigMap (generated from
`identity/SOUL.md` by `kustomization.yaml`), is copied to `/opt/data/SOUL.md` by the `init-hermes-config`
init container, and is loaded by Hermes on every session.

It defines:

* **Identity and scope** — a Lead DevOps/SRE assistant, production-only
  (`your-gcp-project-id` / `your-gke-cluster`, us-west1); read-only everywhere.
* **Default greeting** — the capability profile the bot replies with when a user only says "hi"/"hello"
  (the first thing users see in Slack).
* **Behavior rules** — the read-only guardrails (never mutate production, never read Secrets, never use
  write-capable GitHub/Kubernetes/GCP actions), and the approved local write paths
  (`/opt/data/memory`, `/opt/data/skills`).

**SOUL.md vs skills:** SOUL.md is the *fixed identity* loaded on every turn; skills (below) are
*on-demand* playbooks pulled in only when relevant. Keep durable identity and guardrails in SOUL.md and
task-specific procedure in skills. Hermes caps identity-file size via `context_file_max_chars`.

> The default greeting is currently mirrored in the `lead-devops-sre` skill's "Default greeting" block —
> the same profile in two files. Edit both, or de-duplicate to one, to avoid drift.

Edit `identity/SOUL.md` (version-controlled), then deploy via the **Apply Flow** above — the ConfigMap
re-renders and the rolling restart reloads it.

## 🧩 Add or Update a Hermes Skill

Skills are markdown playbooks (`SKILL.md`) that Hermes loads **on demand**: each skill's one-line
`description` stays in context, and the full body is pulled in only when relevant (progressive
disclosure). Upstream reference: <https://hermes-agent.nousresearch.com/docs/user-guide/features/skills>.

In this deployment the skills directory is **`/opt/data/skills`** (set via `HERMES_SKILLS_DIR` in
`workloads/statefulset.yaml`), on the PVC. The `lead-devops-sre` skill is version-controlled at
`skills/lead-devops-sre/` and installed **declaratively**: `kustomization.yaml` packs it into the
`hermes-agent-declarative-skills` ConfigMap, and `init-hermes-config` copies it onto the PVC on every
roll — the repo copy is the source of truth, the PVC is the install target.

### 📄 SKILL.md format

```text
---
name: <skill-name>
description: Use when the user asks for <clear trigger>.   # one line — this is what triggers the skill
metadata:
  hermes:
    tags: [devops, sre]              # optional, for grouping
    # requires_toolsets: [...]       # optional: activate only when these tools are present
    # fallback_for_toolsets: [...]   # optional: show only when a toolset is unavailable
# required_environment_variables: [SOME_TOKEN]   # optional
---

# <Skill title>

Use this skill when <specific trigger>.

## Behavior
- Be professional, concise, factual; stay within the read-only guardrails.
```

A skill folder may also hold `references/`, `templates/`, `scripts/`, and `assets/` that the agent
pulls on demand with `skill_view(name, path)`.

### 🛠️ Ways to add / manage a skill

**1. Version-controlled file → ConfigMap → PVC (canonical here).** Edit the skill under
`skills/<skill-name>/`, add it to the `hermes-agent-declarative-skills` generator in
`kustomization.yaml` (and a matching `cp` in the `init-hermes-config` script), then deploy:

```bash
kubectl apply -k .
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

**2. `hermes` CLI (inside the pod).** Manage and pull skills from the Hermes hub:

```bash
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- /opt/hermes/.venv/bin/hermes skills list
# also: skills browse | search <q> | inspect <id> | install <id> | uninstall <name> | check | update
```

**3. Dashboard / Slack chat (web UI).** The same operations work as slash commands in the dashboard
(<https://devops.saqlainmushtaq.com>) or Slack — `/skills list`, `/skills browse`, `/skills install <id>` —
and `/<skill-name> <instruction>` activates a skill for one turn.

**4. Agent-authored.** The agent can create/patch skills via its `skill_manage` tool under
`/opt/data/skills`, gated by `skills.write_approval` and the read-only posture. Keep these to
`SKILL.md` content only — no secrets, no operational scripts.

### 🔄 Loading and restart

Skills load on demand into **new** conversations with no restart (the file method needs no restart for
new sessions). **Existing** Slack threads cache the prior skill/prompt, so to make an in-flight session
pick up an edit, roll Hermes (or delete that stale session — see *Slack Session Cache Refresh*), then
verify:

```bash
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=300s
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes skills list | grep '<skill-name>'
```

Dashboard:

```text
URL: https://devops.saqlainmushtaq.com
Username: admin
Password: value stored in the approved production secret manager
```

## 🧪 Sandbox runbook (verified end to end)

Every command below was executed against a Pluralsight/ACG GCP sandbox and is reproduced verbatim.
It deploys Hermes on GKE running **`gemini-3.5-flash` on Vertex AI**, authenticating with **Workload
Identity only** — no service-account JSON key anywhere. Use
`../overlays/sandbox` rather than this directory as the Kustomize root; see that overlay's header for
what it patches out and why.

```bash
export PATH=/opt/homebrew/bin:$PATH
export PROJECT_ID="$(gcloud config get-value project)"   # your sandbox project
export ZONE="us-central1-a"                       # zonal on purpose (sandbox vCPU cap)
export CLUSTER_NAME="gke-cluster"
export NAMESPACE="devops-agent"
export KSA_NAME="hermes-agent"

gcloud config set project "$PROJECT_ID"

# ── 1. Vertex AI API ─────────────────────────────────────────────────────────
gcloud services enable aiplatform.googleapis.com

# ── 2. VPC + GKE cluster (Workload Identity + GKE_METADATA) ──────────────────
# Long-running (~8 min). Background it so a session/turn timeout cannot kill it.
cd ../../gcp
nohup ./gcp-infra.sh --project "$PROJECT_ID" > /tmp/deploy.log 2>&1 &
tail -f /tmp/deploy.log        # wait for "✔ Infrastructure ready"

# ── 3. Confirm Workload Identity is actually on (both layers) ────────────────
gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" \
  --format='value(status,workloadIdentityConfig.workloadPool)'
# -> RUNNING   <project>.svc.id.goog
gcloud container node-pools describe default-pool --cluster "$CLUSTER_NAME" --zone "$ZONE" \
  --format='value(config.workloadMetadataConfig.mode)'
# -> GKE_METADATA   (a cluster-level pool with legacy GCE_METADATA nodes silently breaks WI)

# ── 4. Namespace ─────────────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 5. Bind KSA -> GSA (AFTER the cluster exists; see "Order matters" above) ──
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export GSA_EMAIL="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --role "roles/iam.workloadIdentityUser"

# ── 6. Secrets ───────────────────────────────────────────────────────────────
export VERTEX_GEMINI_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_PASSWORD="$(openssl rand -hex 16)"

# Hash the dashboard password with the exact Hermes image. Running it as a pod
# avoids needing a local Docker daemon; --rm -it can time out on the first pull,
# so create, poll, then read the log.
kubectl -n "$NAMESPACE" run hashgen --restart=Never \
  --image=nousresearch/hermes-agent:v2026.8.3 \
  --env="HERMES_DASHBOARD_PASSWORD=$HERMES_DASHBOARD_PASSWORD" \
  --env="PYTHONPATH=/opt/hermes" \
  --command -- /opt/hermes/.venv/bin/python -c \
  'import os; from plugins.dashboard_auth.basic import hash_password; print("HASH="+hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))'
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/hashgen --timeout=300s
export HERMES_DASHBOARD_PASSWORD_HASH="$(kubectl -n "$NAMESPACE" logs hashgen | sed -n 's/^HASH=//p')"
kubectl -n "$NAMESPACE" delete pod hashgen

kubectl -n "$NAMESPACE" create secret generic hermes-agent-secrets \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HERMES_DASHBOARD_PASSWORD_HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=VERTEX_GEMINI_BRIDGE_API_KEY="$VERTEX_GEMINI_BRIDGE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# The hermes container mounts a GitHub App secret and reads its env vars at
# startup. Supply real credentials to use `gh`; a placeholder is enough to boot
# and does not affect the Vertex path.
openssl genrsa -out /tmp/gh.pem 2048
kubectl -n "$NAMESPACE" create secret generic hermes-agent-github-app \
  --from-literal=app-id="000000" --from-literal=installation-id="000000" \
  --from-file=private-key.pem=/tmp/gh.pem \
  --dry-run=client -o yaml | kubectl apply -f - && rm -f /tmp/gh.pem

# ── 7. Deploy ────────────────────────────────────────────────────────────────
# The ServiceAccount annotation carries __PROJECT_NUMBER__ so the manifests stay
# project-agnostic. Render, substitute, apply — never mutate the tracked files.
kubectl kustomize ../overlays/sandbox \
  | sed "s|__PROJECT_NUMBER__|${PROJECT_NUMBER}|g" \
  | kubectl apply -f -
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=600s
```

### Verification

```bash
# a. Pod identity is the GSA, delivered keylessly by the GKE metadata server
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-gemini-bridge -- python3 -c "
import urllib.request
r=urllib.request.Request('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email',headers={'Metadata-Flavor':'Google'})
print(urllib.request.urlopen(r,timeout=5).read().decode())"
# -> <PROJECT_NUMBER>-compute@developer.gserviceaccount.com

# b. The bridge resolved the project from that identity (no project id in the manifest)
kubectl -n "$NAMESPACE" logs hermes-agent-0 -c vertex-gemini-bridge | grep listening
# -> listening on 0.0.0.0:18182 project=<project> location=global model=gemini-3.5-flash auth=on

# c. A real Vertex Gemini completion, through the sidecar
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-gemini-bridge -- python3 -c "
import json,os,urllib.request
body=json.dumps({'model':'gemini-3.5-flash','messages':[{'role':'user','content':'Reply with exactly: vertex gemini ok'}],'max_tokens':512}).encode()
r=urllib.request.Request('http://127.0.0.1:18182/v1/chat/completions',data=body,
  headers={'Authorization':'Bearer '+os.environ['VERTEX_GEMINI_BRIDGE_API_KEY'],'Content-Type':'application/json'})
d=json.load(urllib.request.urlopen(r,timeout=120))
print(d['model'], repr(d['choices'][0]['message']['content']))"
# -> gemini-3.5-flash 'vertex gemini ok'

# d. Hermes itself is pinned to the model
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c hermes -- sed -n '1,6p' /opt/data/config.yaml
# -> model: {default: gemini-3.5-flash, provider: vertex-gemini-bridge, ...}

# e. End-to-end: drive a real agent turn, then match its token counts against
#    the bridge's Vertex usage line. Equal counts prove the turn went to Vertex.
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c hermes -- sh -lc '
/opt/hermes/.venv/bin/python - <<PY
import json,os,urllib.request
body=json.dumps({"model":"hermes-agent","messages":[{"role":"user","content":"In one short sentence, name the Google model you are running on."}],"stream":False}).encode()
r=urllib.request.Request("http://127.0.0.1:8642/v1/chat/completions",data=body,
  headers={"Authorization":"Bearer "+os.environ["API_SERVER_KEY"],"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(r,timeout=300))
print(d["choices"][0]["message"]["content"]); print(d["usage"])
PY'
# -> "I am running on the Gemini 3.5 Flash model built by Google."
# -> {'prompt_tokens': 13934, 'completion_tokens': 16, ...}
kubectl -n "$NAMESPACE" logs hermes-agent-0 -c vertex-gemini-bridge | grep 'usage model=' | tail -1
# -> usage model=google/gemini-3.5-flash input=13934 output=16 reasoning=459 total=14409

# Dashboard / API (no Traefik in the sandbox)
kubectl -n "$NAMESPACE" port-forward statefulset/hermes-agent 9119:9119 8642:8642
```

### Gotchas confirmed in this environment

| Symptom | Cause / fix |
| --- | --- |
| `404 ... model not found or your project does not have access to it` on `gemini-3.5-flash` | Gemini 3.x resolves **only** at `location=global`. Regional endpoints (`us-central1`, …) 404. |
| Intermittent 404s returning **HTML** instead of JSON, even for models that work | Vertex frontend throttling under rapid-fire probes — not a missing model. Space out requests before concluding anything. |
| `INVALID_ARGUMENT: Identity Pool does not exist` | The KSA→GSA binding ran before the cluster existed. GKE creates the pool. |
| Pod stuck `Pending`, `0/3 nodes are available: 3 Insufficient cpu` | An `e2-medium` has 2 vCPU capacity but only **940m allocatable**, and kube-system already requests 424–886m of it. The sandbox overlay lowers requests to 350m total. |
| `roles/aiplatform.user` cannot be granted | Sandboxes deny `projects.setIamPolicy`, so a dedicated least-privilege GSA can never be authorized and its token 403s on `aiplatform.endpoints.predict`. The Compute Engine default SA already carries `roles/editor`. Outside a sandbox, always prefer the dedicated GSA. |
| Hermes turn hangs with no output, bridge logs `POST … 200` | SSE served over HTTP/1.0 while advertising `connection: keep-alive` — the client waits for a content-length that never arrives. The bridge sends `connection: close`. Hermes streams by default, so this is the common path. |
| `Connect call failed ('127.0.0.1', 19190)` MCP warnings | Expected in the sandbox overlay: the `gcp-mcp-auth-bridge` sidecar is patched out (it needs Google OAuth credentials). Non-fatal — the agent runs without those three read-only MCP servers. |

## 🧪 Validation

Health check from inside the cluster:

```bash
kubectl -n devops-agent run vertex-bridge-curl \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_GEMINI_BRIDGE_API_KEY=$VERTEX_GEMINI_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" http://hermes-agent:18182/health'
```

Chat completion validation:

```bash
kubectl -n devops-agent run vertex-bridge-chat-test \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_GEMINI_BRIDGE_API_KEY=$VERTEX_GEMINI_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS \
    -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" \
    -H "Content-Type: application/json" \
    http://hermes-agent:18182/v1/chat/completions \
    -d "{\"model\":\"gemini-3.5-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: vertex gemini ok\"}],\"stream\":false,\"max_tokens\":128}"'
```

Public endpoint validation:

```bash
curl -sS https://devops.saqlainmushtaq.com/health
```

## 🐚 Runtime Paths and Container Shells

The Vertex deployment does **not** run Claude Code CLI. It uses a Python chat-completions-compatible bridge that sends
requests to Vertex AI Gemini, so `claude` is not expected to exist in the `vertex-gemini-bridge` container.
If you open a shell in that container and run `claude`, `bash: claude: command not found` is correct.

Use the right container and path for the operation:

| Container | Purpose | Important paths |
| --- | --- | --- |
| `hermes` | Hermes gateway, dashboard, Slack sessions, skills, MCP client runtime | Hermes CLI: `/opt/hermes/.venv/bin/hermes`; home/PVC: `/opt/data`; tools: `/opt/data/bin`; skills: `/opt/data/skills`; memory: `/opt/data/memory`; `kubectl`: `/usr/local/bin/kubectl` symlink to `/opt/data/bin/kubectl` |
| `vertex-gemini-bridge` | Python bridge from Hermes to Vertex AI Gemini | bridge script: `/app/vertex_gemini_bridge.py`; health port: `18182`; no `claude` binary |
| `gcp-mcp-auth-bridge` | Loopback OAuth bridge for Google MCP | GCP MCP proxy: `http://127.0.0.1:19190/{logging,monitoring,trace}` |

Useful shell checks:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod

# Hermes CLI and runtime tools live in the hermes container.
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp list
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  sh -lc 'command -v kubectl && kubectl version --client=true'

# The Vertex bridge container is not a Claude Code shell.
kubectl -n devops-agent exec statefulset/hermes-agent -c vertex-gemini-bridge -- \
  sh -lc 'test ! -x "$(command -v claude 2>/dev/null)" && echo "claude CLI is not installed here; this is expected"'
kubectl -n devops-agent exec statefulset/hermes-agent -c vertex-gemini-bridge -- \
  sh -lc 'test -f /app/vertex_gemini_bridge.py && echo "Vertex bridge script present"'
```

## 🎭 Playwright MCP — headless browser for live-app diagnosis

Live-app diagnosis uses the in-cluster **`playwright`** MCP server (Microsoft Playwright MCP, headless
Chromium), configured by `init-hermes-config` in the StatefulSet. It lets the agent load a live app URL,
run the page's JavaScript, and read client-side console errors, failed XHRs, the auth/redirect flow, and
the rendered DOM — things `curl` can't reach. Read-only: the browser only reads pages, it never mutates
cluster or cloud resources.

Available tools:

```text
browser_navigate
browser_snapshot
browser_click
browser_type
browser_fill_form
browser_console_messages
browser_network_requests
browser_take_screenshot
browser_evaluate
browser_wait_for
```

Validate it from the pod:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp list
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test playwright
```

## ♻️ Refreshing stale Slack session state

Hermes Slack threads can keep stale session/tool state from before an MCP server was loaded. If Slack
says an MCP is unavailable but `hermes mcp test <name>` works inside the pod, delete only the stale
Hermes session for that Slack thread and restart the gateway so the Slack runtime reloads the MCP
registry:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod

# 1. Confirm the MCP works from the Hermes runtime.
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test playwright

# 2. Find the stale Slack session.
kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes sessions list

# 3. Delete only the stale session ID, then restart Hermes.
STALE_SESSION_ID="<session-id-from-list>"
printf 'y\n' | kubectl -n devops-agent exec -i statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/hermes sessions delete "$STALE_SESSION_ID"
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=10m
```

## 🔒 Security hardening

The production agent may use only the tools baked in via the init containers and must
not execute arbitrary code or install anything at runtime. Enforced declaratively in the generated
`config.yaml`:

- **`agent.disabled_toolsets: [code_execution]`** — the `execute_code` (arbitrary Python) tool is disabled.
- **`security.allow_lazy_installs: false`** — disables Hermes' *own* lazy installer (provider
  post-setup hooks). This alone does not stop shell installs — hence the next two layers.
- **`block-installs` pre_tool_call hook** — `/opt/data/hooks/block-installs.py` (written by
  `init-hermes-config`, registered via `hooks.pre_tool_call` + `hooks_auto_accept: true`)
  hard-blocks install commands before they run: `uv`, `pip`, `apt`/`dpkg`/`apk`/`yum`/`dnf`,
  `npm`/`pnpm`/`yarn`/`npx`, `gem/cargo/go install`, `conda`, and `curl|sh` / `wget|sh`
  pipe-to-shell installers.
- **`uv` removed from the container** (postStart `rm -f /usr/local/bin/uv`; `pip` is not in the
  image) — only `kubectl` and `gh` (installed by the init containers) are available.
- The agent runs non-root (uid 10000) with read-only RBAC.

Verify: `hermes tools list | grep code_execution` → `✗ disabled`.

## 💰 Capabilities & cost (2026-07-02)

- **Live-domain diagnosis (read-only HTTP).** The production Lead SRE agent may `curl`/fetch app
  URLs under the `*.saqlainmushtaq.com` families (host inventory in
  `your-github-org/argocd`) to check status/headers/redirects/API responses. `curl` sees server
  responses, not client-side JS errors. (No `kubectl exec`/`debug` in production — read-only only.)
- **Cost optimization** (init-generated `config.yaml`): `agent.max_turns: 60` (was 90),
  `tool_loop_guardrails.hard_stop_enabled: true`, and **all bundled skills stripped** via
  `hermes skills opt-out --remove` (smaller system prompt → cheaper). `compression.threshold`
  kept at 0.85.
