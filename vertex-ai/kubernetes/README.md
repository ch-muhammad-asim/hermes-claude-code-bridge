# ☸️ Vertex AI Claude — Kubernetes Deployment

This directory is the **self-contained Kustomize root** for the production Hermes + Vertex Claude
deployment: `kubectl apply -k .` renders and applies the whole stack.

Target production environment:

```text
GCP project: your-gcp-project-id
Vertex location: global
Claude model: claude-opus-4-8
```

## 🗂️ Directory layout

```text
kubernetes/
├── kustomization.yaml        # the Kustomize root — apply with `kubectl apply -k .`
├── bridge/                   # vertex_claude_bridge.py + requirements (+ local-dev README)
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
  -> vertex-claude-bridge
  -> Google Vertex AI Anthropic partner model endpoint
  -> claude-opus-4-8
```

The bridge code lives in [`bridge/vertex_claude_bridge.py`](bridge/vertex_claude_bridge.py) — a
single copy inside this Kustomize root (no duplicate source tree, no load-restrictor overrides).

Create the `devops-agent` namespace idempotently during the apply flow.

## ✅ Runtime Requirements

- `claude-opus-4-8` is enabled in Vertex AI Model Garden for `your-gcp-project-id`.
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

## ⚙️ Production Environment Variables

The bridge should run with:

```text
ANTHROPIC_VERTEX_PROJECT_ID=your-gcp-project-id
CLOUD_ML_REGION=global
ANTHROPIC_MODEL=claude-opus-4-8
VERTEX_CLAUDE_BRIDGE_API_KEY=<kubernetes-secret-value>
VERTEX_CLAUDE_MAX_TOKENS=8192
VERTEX_CLAUDE_TIMEOUT_SECONDS=300
VERTEX_CLAUDE_PROMPT_CACHING=1
VERTEX_CLAUDE_MAX_RETRIES=2
VERTEX_CLAUDE_CACHE_TTL=1h
```

These match the existing Vertex environment convention for production workloads.

## 🔌 Hermes Provider Config

Hermes should point to the bridge using a custom Hermes provider:

```yaml
model:
  default: claude-opus-4-8
  provider: vertex-claude-bridge
  base_url: http://127.0.0.1:18182/v1
  api_mode: chat_completions

providers:
  vertex-claude-bridge:
    name: Vertex Claude Bridge
    base_url: http://127.0.0.1:18182/v1
    api_key: ${VERTEX_CLAUDE_BRIDGE_API_KEY}
    default_model: claude-opus-4-8
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
hermes-agent-vertex-bridge        -> bridge/vertex_claude_bridge.py + bridge/requirements.txt
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

Authenticate to the production GKE cluster:

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
export GSA_NAME="hermes-vertex"
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Google service account the pod acts as
gcloud iam service-accounts create "$GSA_NAME" \
  --project "$PROJECT_ID" \
  --display-name "Hermes Vertex AI bridge (Workload Identity)"

# 2. Vertex AI invocation (Claude on the Anthropic partner endpoint) — the only role it needs
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${GSA_EMAIL}" \
  --role "roles/aiplatform.user"

# 3. Allow the KSA to impersonate the GSA (the Workload Identity binding)
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --role "roles/iam.workloadIdentityUser"
```

The KSA-side annotation (`iam.gke.io/gcp-service-account: hermes-vertex@…`) is already declared in
`rbac/serviceaccount.yaml` and applied by the Kustomize flow below. Verify from the pod after deploy —
ADC should resolve to the GSA via the metadata server:

```bash
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-claude-bridge -- \
  python3 -c 'import google.auth; c, p = google.auth.default(); print("project:", p)'
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c vertex-claude-bridge -- \
  python3 -c "import urllib.request; r = urllib.request.Request('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email', headers={'Metadata-Flavor': 'Google'}); print(urllib.request.urlopen(r, timeout=3).read().decode())"
# expected: hermes-vertex@your-gcp-project-id.iam.gserviceaccount.com
```

Create the bridge API key secret:

```bash
export VERTEX_CLAUDE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_IMAGE='nousresearch/hermes-agent:v2026.7.20'
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
  --from-literal=VERTEX_CLAUDE_BRIDGE_API_KEY="$VERTEX_CLAUDE_BRIDGE_API_KEY" \
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
`init-hermes-config` init container, and the `hermes` container. (The `vertex-claude-bridge` and
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
OLD=v2026.7.20; NEW=<new-dated-tag>
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

## 🧪 Validation

Health check from inside the cluster:

```bash
kubectl -n devops-agent run vertex-bridge-curl \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_CLAUDE_BRIDGE_API_KEY=$VERTEX_CLAUDE_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" http://hermes-agent:18182/health'
```

Chat completion validation:

```bash
kubectl -n devops-agent run vertex-bridge-chat-test \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_CLAUDE_BRIDGE_API_KEY=$VERTEX_CLAUDE_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS \
    -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" \
    -H "Content-Type: application/json" \
    http://hermes-agent:18182/v1/chat/completions \
    -d "{\"model\":\"claude-opus-4-8\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: vertex opus ok\"}],\"stream\":false,\"max_tokens\":128}"'
```

Public endpoint validation:

```bash
curl -sS https://devops.saqlainmushtaq.com/health
```

## 🐚 Runtime Paths and Container Shells

The Vertex deployment does **not** run Claude Code CLI. It uses a Python chat-completions-compatible bridge that sends
requests to Vertex AI Claude, so `claude` is not expected to exist in the `vertex-claude-bridge` container.
If you open a shell in that container and run `claude`, `bash: claude: command not found` is correct.

Use the right container and path for the operation:

| Container | Purpose | Important paths |
| --- | --- | --- |
| `hermes` | Hermes gateway, dashboard, Slack sessions, skills, MCP client runtime | Hermes CLI: `/opt/hermes/.venv/bin/hermes`; home/PVC: `/opt/data`; tools: `/opt/data/bin`; skills: `/opt/data/skills`; memory: `/opt/data/memory`; `kubectl`: `/usr/local/bin/kubectl` symlink to `/opt/data/bin/kubectl` |
| `vertex-claude-bridge` | Python bridge from Hermes to Vertex AI Claude | bridge script: `/app/vertex_claude_bridge.py`; health port: `18182`; no `claude` binary |
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
kubectl -n devops-agent exec statefulset/hermes-agent -c vertex-claude-bridge -- \
  sh -lc 'test ! -x "$(command -v claude 2>/dev/null)" && echo "claude CLI is not installed here; this is expected"'
kubectl -n devops-agent exec statefulset/hermes-agent -c vertex-claude-bridge -- \
  sh -lc 'test -f /app/vertex_claude_bridge.py && echo "Vertex bridge script present"'
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
