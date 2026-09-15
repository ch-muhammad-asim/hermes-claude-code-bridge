# ☁️ Hermes Vertex AI Deployment

Production deployment of the **Hermes Lead SRE Agent** backed by **Vertex AI Gemini 3.5 Flash**. Hermes
runs with a custom `vertex-gemini-bridge` sidecar that authenticates with GKE Workload Identity and
forwards OpenAI-compatible chat-completions requests to Vertex AI's OpenAI-compatible Gemini endpoint.
This path uses no Claude Code CLI and no Claude subscription session.

```text
Target environment
  GCP project:     your-gcp-project-id
  Vertex location: global
  Model:           gemini-3.5-flash
  Namespace:       devops-agent
```

## 🗂️ Layout

```text
vertex-ai/
├── README.md                 # this file — overview, architecture, security posture, Slack pairing
├── overlays/                 # environment-specific Kustomize overlays (for example sandbox)
└── kubernetes/               # self-contained Kustomize root: `kubectl apply -k kubernetes`
    ├── bridge/               # vertex_gemini_bridge.py + requirements; legacy Claude bridge kept in Git only
    ├── gcp-mcp/              # loopback OAuth bridge for the read-only GCP MCP servers
    ├── github-cli/           # read-only `gh` wrapper
    ├── identity/             # SOUL.md (agent identity)
    ├── skills/               # version-controlled Hermes skills (declaratively installed)
    ├── rbac/ · secrets/ · workloads/
    └── README.md             # deploy runbook
```

## 📚 Documentation map

| Document | Scope |
| --- | --- |
| This file | Overview, architecture, bridge configuration, security posture |
| [`kubernetes/README.md`](kubernetes/README.md) | Kubernetes deploy: apply flow, Workload Identity, secrets, image updates, skills, Playwright MCP, **security hardening** |
| [`kubernetes/bridge/README.md`](kubernetes/bridge/README.md) | Gemini bridge IAM, local dev, validation, troubleshooting, and legacy-Claude note |
| [GCP MCP auth bridge](#-gcp-mcp-auth-bridge-kubernetesgcp-mcp) | Loopback OAuth token bridge for the read-only GCP observability MCPs — secret, IAM, validation |
| [Read-only GitHub CLI](#-read-only-github-cli-kubernetesgithub-cli) | Read-only `gh` wrapper — GitHub App, secret, allowlist, validation |
| [Slack pairing](#-slack-pairing--approve--manage-users) | Approve/manage Slack users via the `hermes pairing` CLI; lockout reset |

## 🏗️ Architecture

```text
Slack / Dashboard / API
  -> Hermes Agent container (nousresearch/hermes-agent)
  -> vertex-gemini-bridge sidecar (127.0.0.1:18182)
  -> Vertex AI OpenAI-compatible chat-completions endpoint
  -> gemini-3.5-flash
```

The pod runs three containers: `hermes` (gateway, dashboard, MCP client, skills),
`vertex-gemini-bridge` (model bridge), and `gcp-mcp-auth-bridge` (loopback OAuth for the read-only GCP
MCP servers). GitHub access is provided by the read-only `gh` CLI installed in-pod (not an MCP server).
Slack is the native Hermes bot integration (home channel + pairing) — used to receive and answer
messages, not a data MCP. The full integration map is in the Kubernetes runbook.

## 🌉 The vertex-gemini-bridge

`kubernetes/bridge/vertex_gemini_bridge.py` is a thin chat-completions-compatible proxy:

- exposes `GET /health`, `GET /v1/models`, and `POST /v1/chat/completions`;
- authenticates to Google with ADC / GKE Workload Identity;
- gates Hermes-to-bridge calls with `VERTEX_GEMINI_BRIDGE_API_KEY`;
- qualifies the model ID with the `google/` publisher prefix required by Vertex and normalizes it back
  to `gemini-3.5-flash` in responses;
- forwards tools, tool calls, tool results, and SSE streaming directly — **no Anthropic schema
  translation** is required for the deployed Gemini path;
- retries transient Vertex `429/500/502/503/504` and connection failures with bounded backoff;
- logs input, output, reasoning, and total token usage;
- rejects requests over `VERTEX_GEMINI_MAX_PROMPT_CHARS`.

It runs as a pod-local sidecar, reachable only over the pod network / internal Service, and
authenticates to Google with Application Default Credentials via **GKE Workload Identity**. The
`hermes-agent` Kubernetes ServiceAccount is bound to the production Google service account carrying
the Vertex permissions, so credentials are keyless and short-lived from the metadata server. No
service-account JSON key is stored in Git or Kubernetes.

### ⚙️ Configuration

Set on the `vertex-gemini-bridge` container (see `kubernetes/workloads/statefulset.yaml`):

| Variable | Production value | Purpose |
| --- | --- | --- |
| `CLOUD_ML_REGION` | `global` | Vertex location for Gemini 3.x |
| `GEMINI_MODEL` | `gemini-3.5-flash` | **Single production model default** |
| `VERTEX_GEMINI_BRIDGE_API_KEY` | secret | Bearer key Hermes uses to call the bridge |
| `VERTEX_GEMINI_MAX_TOKENS` | `8192` | Output cap |
| `VERTEX_GEMINI_TIMEOUT_SECONDS` | `300` | Per-request timeout |
| `VERTEX_GEMINI_MAX_RETRIES` | `2` | Retry budget for transient Vertex errors |
| `VERTEX_GEMINI_MAX_PROMPT_CHARS` | `200000` default | Bridge-side request-size guard |

The bridge normally resolves the GCP project from ADC / Workload Identity. `VERTEX_GEMINI_PROJECT_ID`,
`GOOGLE_CLOUD_PROJECT`, and `GCP_PROJECT_ID` are optional project overrides. `VERTEX_GEMINI_LOCATION`
and `VERTEX_GEMINI_MODEL` are aliases for `CLOUD_ML_REGION` and `GEMINI_MODEL`.

### Reliability and telemetry

- **Retries:** transient Vertex `429/500/502/503/504` and connection errors are retried with bounded
  exponential backoff before the final error is returned to Hermes.
- **Streaming:** Vertex already emits OpenAI-compatible SSE chunks. The bridge relays them and closes
  the HTTP/1.0 connection explicitly so clients do not wait indefinitely for a content length.
- **Telemetry:** both streaming and non-streaming paths log token usage, including Gemini reasoning
  tokens when Vertex reports them.
- **Prompt-size guard:** `VERTEX_GEMINI_MAX_PROMPT_CHARS` bounds request message content before a Vertex
  call is made.

### Legacy Claude bridge

`kubernetes/bridge/vertex_claude_bridge.py` remains in Git as an alternate/reference implementation for
Vertex Anthropic partner models. It is **not packaged by the production Kustomization**, is not selected
by the StatefulSet, and is not configured as a model fallback. The supported deployment described in
this directory has one model default: **`gemini-3.5-flash`**.

## 🔎 GCP MCP auth bridge (`kubernetes/gcp-mcp/`)

`gcp_mcp_auth_bridge.py` is a loopback proxy that gives Hermes **durable, read-only** access to the
Google Cloud MCP observability endpoints. Hermes points at `http://127.0.0.1:19190/{logging,monitoring,trace}`
and does no OAuth at all; the bridge injects `Authorization: Bearer` tokens minted from one long-lived
**offline refresh token**, caching each access token until ~2 minutes before expiry. It forwards only
`GET`/`POST` (`DELETE` is rejected with 405), and the pod containers share a network namespace, so one
proxy serves the whole pod.

> **Why an offline refresh token:** the standard MCP OAuth (PKCE) flow never sends Google's
> `access_type=offline` parameter, so interactive logins get an access-token-only grant that dies
> after one hour with *"token expired, needs re-authorization"*. The bridge holds the one grant type
> Google will actually refresh.

**Routes → upstreams:**

```text
/logging     -> https://logging.googleapis.com/mcp
/monitoring  -> https://monitoring.googleapis.com/mcp
/trace       -> https://cloudtrace.googleapis.com/mcp
```

**Required Secret — `hermes-agent-google-oauth`** (read via `envFrom` by the `gcp-mcp-auth-bridge`
container; the bridge refuses to start if any key is missing):

| Key | Purpose |
| --- | --- |
| `GOOGLE_MCP_OAUTH_CLIENT_ID` | OAuth **web** client ID (`…apps.googleusercontent.com`) |
| `GOOGLE_MCP_OAUTH_CLIENT_SECRET` | The web client's secret |
| `GOOGLE_MCP_OAUTH_REFRESH_TOKEN` | Offline refresh token for the read-only identity |

(`GCP_MCP_TOKEN_PROXY_PORT` is optional; default `19190`.)

**Read-only IAM for the OAuth identity** (project-scoped):

```bash
export PROJECT_ID="your-gcp-project-id"
export MCP_USER="hermes-sre@your-domain.com"
for role in roles/mcp.toolUser roles/logging.viewer roles/monitoring.viewer roles/cloudtrace.user; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "user:${MCP_USER}" --role "$role"
done
```

**One-time setup** — create an OAuth *web* client in the GCP console (redirect URI
`http://127.0.0.1:19191/callback`), obtain the refresh token with an `access_type=offline` +
`prompt=consent` authorization (if no `refresh_token` comes back, revoke the prior grant at
<https://myaccount.google.com/permissions> and rerun), then store all three values:

```bash
kubectl -n devops-agent create secret generic hermes-agent-google-oauth \
  --from-literal=GOOGLE_MCP_OAUTH_CLIENT_ID="$GOOGLE_MCP_OAUTH_CLIENT_ID" \
  --from-literal=GOOGLE_MCP_OAUTH_CLIENT_SECRET="$GOOGLE_MCP_OAUTH_CLIENT_SECRET" \
  --from-literal=GOOGLE_MCP_OAUTH_REFRESH_TOKEN="<printed value>" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

**Validate:**

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  sh -lc 'curl -sS http://127.0.0.1:19190/healthz'

kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-logging-sre-readonly
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-monitoring-sre-readonly
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-trace-sre-readonly
```

## 🐙 Read-only GitHub CLI (`kubernetes/github-cli/`)

`github-cli/gh` is a POSIX-shell wrapper that replaces a GitHub MCP server. It is symlinked to
`/usr/local/bin/gh` in the `hermes` container and does two jobs on **every call**:

1. **Mints a fresh GitHub App installation token.** App tokens expire after ~1 hour; per-call minting
   avoids stale-token failures.
2. **Enforces a read-only allowlist.** `repo`/`pr`/`issue`/`run`/`workflow`/`release`/`label`/`gist`
   allow only the approved read operations; `gh api` allows only `GET`/`HEAD` and rejects request-body
   flags. Everything else is blocked before it reaches GitHub.

**Required Secret — `hermes-agent-github-app`** (mounted read-only at
`/var/run/secrets/hermes-github-app`, mode `0400`):

| Key | Purpose |
| --- | --- |
| `app-id` | GitHub App ID |
| `installation-id` | Numeric installation ID on your org |
| `private-key.pem` | The App's private key |

Create a GitHub App (for example `hermes-sre-readonly`) with **read-only** repository permissions only,
install it on the approved organization/repositories, then create the Secret:

```bash
: "${GITHUB_APP_ID:?export GITHUB_APP_ID first}"
: "${GITHUB_APP_INSTALLATION_ID:?export GITHUB_APP_INSTALLATION_ID first}"
: "${GITHUB_APP_PRIVATE_KEY_FILE:?export GITHUB_APP_PRIVATE_KEY_FILE first}"

kubectl -n devops-agent create secret generic hermes-agent-github-app \
  --from-literal=app-id="$GITHUB_APP_ID" \
  --from-literal=installation-id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=private-key.pem="$GITHUB_APP_PRIVATE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

Validate reads and the write block:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh api /rate_limit --jq .resources.core.limit'
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh repo list <your-org> --limit 3'
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh api -X POST /repos/<your-org>/<repo>/issues; echo "exit=$?"'
```

## 🔒 Security posture

- **GKE Workload Identity:** the `hermes-agent` ServiceAccount receives keyless, short-lived Google
  credentials and only the IAM needed by the deployment.
- **Read-only production access:** Kubernetes, GitHub, GCP observability, and databases are constrained
  by independent permission layers; the agent investigates and returns remediation instead of mutating
  production.
- **Runtime hardening:** `agent.disabled_toolsets: [code_execution]`,
  `security.allow_lazy_installs: false`, the `block-installs` pre-tool hook, removed `uv`, non-root
  execution, and restricted Linux capabilities reduce the runtime attack surface.
- **Focused skill set:** bundled Hermes skills are removed and only the Git-owned `lead-devops-sre`
  skill is installed, reducing prompt overhead and keeping the agent focused.
- **Model consistency:** the production Kustomization, StatefulSet, identity, and capability skill all
  identify **`gemini-3.5-flash`** as the single Vertex model default.
- **Bridge isolation:** the model bridge is not exposed publicly; it stays behind the pod-local/internal
  service path and its bearer key.

## 🧭 Why the Vertex path

Versus driving Hermes through a Claude Code CLI bridge, this deployment gives native Kubernetes
ServiceAccount RBAC, GCP billing and IAM, and no dependency on `claude -p` or a Claude subscription.
For Gemini, Vertex already exposes the OpenAI-compatible API shape Hermes needs, so the production
bridge remains a small authentication/reliability proxy rather than a schema translator.

## 🛠️ Local development and deployment

- Gemini bridge IAM, local run, and ADC validation: [`kubernetes/bridge/README.md`](kubernetes/bridge/README.md).
- Cluster deploy (apply flow, secrets, image bump, skills): [`kubernetes/README.md`](kubernetes/README.md).

## 💬 Slack pairing — approve & manage users

Approve Slack users for the Hermes SRE bot **from the CLI**. The dashboard Pairing page's
**APPROVE button is broken** in the documented runtime (it sends the UI hash-prefix, not the real code),
so use the CLI flow below.

### 📍 Where to run

All commands run **inside the `hermes` container** — use a pod shell, or exec in:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod
kubectl exec -it hermes-agent-0 -n devops-agent -c hermes -- bash
```

Then put `hermes` on `PATH` for the session:

```bash
export PATH=/opt/hermes/.venv/bin:$PATH
```

### 🧩 How pairing works

1. A user DMs the Slack bot. The bot replies with a **pairing code** and asks the owner to run
   `hermes pairing approve slack <CODE>`.
2. **The code in the user's DM is the real code** — approve that value.
3. Codes expire after 1 hour and can only be approved while their pending request is live.
4. The value shown in the dashboard can be a hash prefix rather than the real pairing code; do not
   use it for CLI approval.

### ✅ Approve a Slack user

```bash
export PATH=/opt/hermes/.venv/bin:$PATH
hermes pairing approve slack <CODE>
hermes pairing list
```

### 📋 List, revoke, clear pending

```bash
hermes pairing list
hermes pairing revoke slack <SLACK_USER_ID>
hermes pairing clear-pending
```

### 🛟 Add a user directly (code lost/expired)

Approve straight from the Slack user ID only when the normal pairing flow cannot be recovered:

```bash
python3 - <<'PY'
import json, time
p = "/opt/data/pairing/slack-approved.json"
d = json.load(open(p))
d["U01ABCDE23"] = {"user_name": "Alex", "approved_at": time.time()}
json.dump(d, open(p, "w"), indent=2)
print("approved")
PY
hermes pairing list
```

### 🔓 Clear a lockout (HTTP 429)

Five failed approvals can trip the pairing rate limit. Clear only the rate-limit state:

```bash
rm -f /opt/data/pairing/_rate_limits.json
```

### 🔄 If changes do not take effect

```bash
kubectl delete pod hermes-agent-0 -n devops-agent
```

The StatefulSet recreates the pod and the `/opt/data` PVC preserves approvals, pending requests, and
other Hermes state.

### 🚨 Pairing gotchas

- Use the real code delivered in the user's Slack DM for CLI approval.
- Codes expire after 1 hour.
- `hermes` lives at `/opt/hermes/.venv/bin/hermes` if it is not on `PATH`.
- Pairing state lives on the PVC under `/opt/data/pairing/` and survives pod restarts.
