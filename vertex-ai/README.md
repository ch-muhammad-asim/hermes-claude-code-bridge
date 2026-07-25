# ☁️ Hermes Vertex AI Deployment

Production deployment of the **Hermes Lead SRE Agent** backed by **Vertex AI Claude Opus 4.8**. Hermes
runs with a custom `vertex-claude-bridge` sidecar that translates its chat-completions calls into Vertex
AI Anthropic Messages requests. This path uses no Claude Code CLI and no Claude subscription session.

```text
Target environment
  GCP project:     your-gcp-project-id
  Vertex location: global
  Model:           claude-opus-4-8
  Namespace:       devops-agent
```

## 🗂️ Layout

```text
vertex-ai/
├── README.md                 # this file — overview, architecture, security posture, Slack pairing
└── kubernetes/               # self-contained Kustomize root: `kubectl apply -k kubernetes`
    ├── bridge/               # vertex_claude_bridge.py + requirements (+ local-dev README)
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
| [`kubernetes/bridge/README.md`](kubernetes/bridge/README.md) | Bridge IAM, local dev, run, in-cluster validation, troubleshooting |
| [GCP MCP auth bridge](#-gcp-mcp-auth-bridge-kubernetesgcp-mcp) (below) | Loopback OAuth token bridge for the read-only GCP observability MCPs — secret, IAM, validation |
| [Read-only GitHub CLI](#-read-only-github-cli-kubernetesgithub-cli) (below) | Read-only `gh` wrapper — GitHub App, secret, allowlist, validation |
| [Slack pairing](#-slack-pairing--approve--manage-users) (below) | Approve/manage Slack users via the `hermes pairing` CLI (dashboard APPROVE is broken); lockout reset |

## 🏗️ Architecture

```text
Slack / Dashboard / API
  -> Hermes Agent container (nousresearch/hermes-agent)
  -> vertex-claude-bridge sidecar (127.0.0.1:18182)
  -> Vertex AI Anthropic partner endpoint
  -> claude-opus-4-8
```

The pod runs three containers: `hermes` (gateway, dashboard, MCP client, skills), `vertex-claude-bridge`
(model bridge), and `gcp-mcp-auth-bridge` (loopback OAuth for the read-only GCP MCP servers). GitHub
access is provided by the read-only `gh` CLI installed in-pod (not an MCP server). Slack is the native
Hermes bot integration (home channel + pairing) — used to receive and answer messages, not a data MCP.
The full integration map is in the runbook.

## 🌉 The vertex-claude-bridge

`kubernetes/bridge/vertex_claude_bridge.py` is a chat-completions-compatible HTTP shim:

* Exposes `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`.
* Translates Hermes tool definitions, tool calls, and tool results to and from the Anthropic Messages
  shape, preserving the full tool loop.
* Calls the Vertex Anthropic partner endpoint (`:rawPredict`, `anthropic_version: vertex-2023-10-16`).
* For `stream: true`, calls `rawPredict` and wraps the final response in chat-completions SSE chunks
  (Vertex partner-model streaming differs from the SSE shape Hermes expects).
* Resolves Slack screenshot images from the cache under `/opt/data/image_cache`.

It runs as a pod-local sidecar, reachable only over `127.0.0.1` / ClusterIP, and authenticates to Google
with Application Default Credentials via **GKE Workload Identity** — the `hermes-agent` ServiceAccount is
bound to the `hermes-vertex` Google service account (`roles/aiplatform.user` only), so credentials are
keyless and short-lived from the metadata server. No service-account JSON key anywhere.

### ⚙️ Configuration

Set on the `vertex-claude-bridge` container (see `kubernetes/workloads/statefulset.yaml`):

| Variable | Production value | Purpose |
| --- | --- | --- |
| `ANTHROPIC_VERTEX_PROJECT_ID` | `your-gcp-project-id` | Vertex project |
| `CLOUD_ML_REGION` | `global` | Vertex location |
| `ANTHROPIC_MODEL` | `claude-opus-4-8` | Model |
| `VERTEX_CLAUDE_BRIDGE_API_KEY` | (secret) | Bearer key Hermes uses to call the bridge |
| `VERTEX_CLAUDE_MAX_TOKENS` | `8192` | Output cap |
| `VERTEX_CLAUDE_TIMEOUT_SECONDS` | `300` | Per-request timeout |
| `VERTEX_CLAUDE_PROMPT_CACHING` | `1` | Anthropic prompt caching (kill-switch: `0`) |
| `VERTEX_CLAUDE_MAX_RETRIES` | `2` | Retry budget for transient Vertex errors |
| `VERTEX_CLAUDE_CACHE_TTL` | `1h` | Prompt-cache TTL — `1h` survives interactive Slack-thread gaps; `5m` for dense traffic |

The generic aliases `GOOGLE_CLOUD_PROJECT` / `GCP_PROJECT_ID` / `VERTEX_CLAUDE_LOCATION` /
`VERTEX_CLAUDE_MODEL` are also accepted.

### 💰 Cost and reliability

* **Prompt caching.** Vertex has no top-level automatic caching, so the bridge sets
  `cache_control: {type: ephemeral}` explicitly on the stable prefix (last tool, system prompt, last
  message block), caching the large system + tools + history prefix. `claude-opus-4-8` requires a
  ≥4096-token prefix for a cache entry to form. Disable with `VERTEX_CLAUDE_PROMPT_CACHING=0`.
* **Retries.** Transient Vertex `429/500/502/503/504` and connection errors are retried with bounded
  exponential backoff before surfacing to Hermes as a `502`.
* **Telemetry.** Every request logs token usage including cache hits:
  `[vertex-claude-bridge] usage model=… input=… output=… cache_write=… cache_read=…`. Pricing for cost
  derivation: `claude-opus-4-8` is $5 / 1M input, $25 / 1M output; cache reads bill ≈ 0.1× input.

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
# bridge is healthy (shared pod network — probe from the hermes container)
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  sh -lc 'curl -sS http://127.0.0.1:19190/healthz'                     # -> ok

# MCP servers resolve through it
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-logging-sre-readonly
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-monitoring-sre-readonly
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  /opt/hermes/.venv/bin/hermes mcp test gcp-trace-sre-readonly

# token minting activity
kubectl -n devops-agent logs hermes-agent-0 -c gcp-mcp-auth-bridge --tail=20
```

## 🐙 Read-only GitHub CLI (`kubernetes/github-cli/`)

`github-cli/gh` is a POSIX-shell wrapper that replaces a GitHub MCP server. It is symlinked to
`/usr/local/bin/gh` in the `hermes` container (postStart hook) and does two jobs on **every call**:

1. **Mints a fresh GitHub App installation token.** App tokens expire after ~1 hour; a server that
   mints once at startup starts returning `401 Bad credentials` an hour later. Per-call minting
   (JWT signed with the App key → installation access token) makes that failure mode impossible.
2. **Enforces a read-only allowlist.** `repo`/`pr`/`issue`/`run`/`workflow`/`release`/`label`/`gist`
   allow only `list|view|diff|checks|download|status`; `search`/`status` pass; `gh api` allows only
   `GET`/`HEAD` and denies every body/field flag (`-f`/`-F`/`--field`/`--raw-field`/`--input`).
   Everything else exits 64 with `blocked by the read-only SRE policy`. This is defense-in-depth on
   top of the App's own read-only permissions.

**Required Secret — `hermes-agent-github-app`** (mounted read-only at
`/var/run/secrets/hermes-github-app`, mode `0400`):

| Key | Purpose |
| --- | --- |
| `app-id` | GitHub App ID |
| `installation-id` | Numeric installation ID on your org |
| `private-key.pem` | The App's private key |

**One-time setup** — create a GitHub App (e.g. `hermes-sre-readonly`) under your org → *Settings →
Developer settings → GitHub Apps* with **read-only** permissions only (Contents, Metadata, Pull
requests, Actions, Checks; no write scopes), install it on the org, note the installation ID from
`https://github.com/organizations/<org>/settings/installations/<INSTALLATION_ID>`, generate a private
key, then create the Secret (never commit the PEM or render it into a ConfigMap):

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

**Validate:**

```bash
# reads work (fresh token minted per call)
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh api /rate_limit --jq .resources.core.limit'
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh repo list <your-org> --limit 3'

# writes are refused by the wrapper (exit 64, never reaches GitHub)
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
  bash -lc 'gh api -X POST /repos/<your-org>/<repo>/issues; echo "exit=$?"'   # -> blocked, exit=64
```

The real `gh` binary is installed by the `init-runtime-tools` init container — latest release,
resolved and **checksum-verified** against GitHub's published `checksums.txt` at install time.

## 🔒 Security posture

* **GKE Workload Identity** — the `hermes-agent` ServiceAccount is bound to a dedicated Google service
  account carrying only `roles/aiplatform.user`; ADC mints keyless, short-lived credentials from the
  metadata server. No service-account JSON key in Git or Kubernetes. Setup:
  [`kubernetes/README.md`](kubernetes/README.md) → **Workload Identity (Vertex AI)**.
* **Read-only everywhere**, enforced in independent layers (Kubernetes RBAC, GitHub App scope,
  viewer-only GCP IAM, read-only MCP allowlists, the read-only `gh` wrapper). GitHub, Slack, Kubernetes,
  GCP, and databases are all read-only — the agent investigates and hands back the fix; it never mutates
  production. Details in the runbook.
* **Runtime hardening.** The agent runs only the tools baked in via the init
  containers and cannot execute arbitrary code or install anything at runtime:
  `agent.disabled_toolsets: [code_execution]` (no arbitrary Python / `execute_code`) and
  `security.allow_lazy_installs: false` (no on-the-fly package/binary installs), a `block-installs`
  pre_tool_call hook, `uv` removed, plus non-root (uid 10000). See `kubernetes/README.md` →
  **Security hardening**.
* **Cost optimization** — `agent.max_turns: 60`, `tool_loop_guardrails.hard_stop_enabled: true`,
  and all bundled skills stripped (`hermes skills opt-out --remove`; only the local `lead-devops-sre`
  skill remains → smaller system prompt). Prompt caching + retries in the bridge (above).
* **Live-domain diagnosis** — the agent may load app URLs under the `*.saqlainmushtaq.com` families in the read-only Playwright browser (or `curl` for raw HTTP) to check the rendered page, console/network, status, and headers.
* The bridge is never exposed publicly; it listens on a pod-local port behind the bridge API key.

## 🧭 Why the Vertex path

Versus driving Hermes through a Claude Code CLI bridge, the Vertex path gives native Kubernetes
ServiceAccount RBAC, GCP billing and IAM, and no dependency on `claude -p` or a Claude subscription —
a better fit for shared production. The tradeoff is that we own the translation bridge; the production
hardening that implies — prompt caching, retries, and cost telemetry — is implemented in
`vertex_claude_bridge.py` (see **Cost and reliability** above).

## 🛠️ Local development and deployment

* Bridge IAM, local run, and ADC validation: [`kubernetes/bridge/README.md`](kubernetes/bridge/README.md).
* Cluster deploy (apply flow, secrets, image bump, skills): [`kubernetes/README.md`](kubernetes/README.md).

## 💬 Slack pairing — approve & manage users

Approve Slack users for the Hermes SRE bot **from the CLI**. The dashboard Pairing page's
**APPROVE button is broken** (it sends the UI hash-prefix, not the real code — see
[Gotchas](#-pairing-gotchas)), so always use the CLI below.

### 📍 Where to run

All commands run **inside the `hermes` container** — use the Lens "Pod Shell", or exec in:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod   # your kube context for prod
kubectl exec -it hermes-agent-0 -n devops-agent -c hermes -- bash
```

Then, in the pod, put `hermes` on `PATH` for the session (it lives in the venv):

```bash
export PATH=/opt/hermes/.venv/bin:$PATH
```

One-liner alternative: `kubectl exec hermes-agent-0 -n devops-agent -c hermes -- sh -c 'export PATH=/opt/hermes/.venv/bin:$PATH; hermes pairing list'`.

### 🧩 How pairing works (read first)

1. A user DMs the Slack bot. The bot replies with a **pairing code** (e.g. `UUV4ERY7`) and asks the owner to run `hermes pairing approve slack <CODE>`.
2. **The code in the user's DM is the real code** — that's what you approve.
3. Codes **expire after 1 hour** and can only be approved while their pending request is live.
4. ⚠️ The code shown in the **dashboard** (e.g. `2db2eee9`) is a **hash prefix, NOT the code** — it never works. Use the code from the user's DM.

### ✅ Approve a Slack user (normal flow)

```bash
export PATH=/opt/hermes/.venv/bin:$PATH
hermes pairing approve slack <CODE>      # e.g. hermes pairing approve slack UUV4ERY7
hermes pairing list                      # verify they appear under "Approved Users"
```

### 📋 List, revoke, clear pending

```bash
export PATH=/opt/hermes/.venv/bin:$PATH
hermes pairing list                              # pending + approved
hermes pairing revoke slack <SLACK_USER_ID>      # e.g. U01ABCDE23
hermes pairing clear-pending                      # clears pending only; approved untouched
```

### 🛟 Add a user directly (code lost/expired)

Approve straight from the Slack user ID (from the pending list / Slack profile), bypassing the code:

```bash
python3 - <<'PY'
import json, time
p = "/opt/data/pairing/slack-approved.json"
d = json.load(open(p))
d["U01ABCDE23"] = {"user_name": "Alex", "approved_at": time.time()}   # <- set ID + name
json.dump(d, open(p, "w"), indent=2)
print("approved")
PY
export PATH=/opt/hermes/.venv/bin:$PATH
hermes pairing list                      # verify
```

The store re-reads this file on every message, so it takes effect right away — if not, restart the pod (below).

### 🔓 Clear a lockout (HTTP 429)

Five failed approvals (usually from the broken dashboard button) trip a 1-hour lockout. Clear it:

```bash
rm -f /opt/data/pairing/_rate_limits.json    # resets failure counter + lockout (rate-limit state only)
```

Then re-run the approve. (The CLI's hint prints `~/.hermes/platforms/pairing/_rate_limits.json`, which is **wrong** on this pod — the real path is `/opt/data/pairing/_rate_limits.json`.)

### 🔄 If changes don't take effect — restart the pod

```bash
kubectl delete pod hermes-agent-0 -n devops-agent
# StatefulSet recreates it (~30-60s). State under /opt/data (PVC) — approvals, pending,
# rate-limits — persists across the restart, so nothing is lost.
```

Lighter option first: the dashboard's **"Restart Gateway"** button restarts just the gateway process; if that doesn't pick up the change, do the full pod restart. Either way the PVC pairing files are preserved.

### 🚨 Pairing gotchas

- **Dashboard APPROVE button is broken** — it sends the hash-prefix shown in the UI, which never matches a real code → fails every time → 5 fails trips the 1-hour lockout. Use the CLI.
- **Dashboard "code" ≠ real code** — the UI shows `hash[:8]` (e.g. `2db2eee9`); the real code (e.g. `UUV4ERY7`) is only in the user's bot DM.
- **Codes expire after 1 hour** and only approve while their pending request still exists. If expired, have the user DM the bot again, or use the direct-add workaround.
- **`hermes` is not on `PATH`** — always `export PATH=/opt/hermes/.venv/bin:$PATH` first (or call `/opt/hermes/.venv/bin/hermes`).
- **State is on the PVC** at `/opt/data/pairing/` (`slack-approved.json`, `slack-pending.json`, `_rate_limits.json`) — survives pod restarts.
