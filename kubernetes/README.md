# ☸️ Hermes Agent — Kubernetes Deployment

Deploys the production Hermes Agent (gateway + dashboard) with a Claude Code bridge sidecar to GKE at `https://hermes.saqlainmushtaq.com`.

> 🧭 **What this is:** Hermes is an agent gateway. It runs a `hermes` container (brain + dashboard) and a `claude-bridge` sidecar (runs the `claude` CLI as the model backend). It chats in a web dashboard, runs skills, and investigates via read-only MCP tools — read-only by default.

## 📁 Layout

This is a Kustomize base — `kubectl apply -k .` renders everything. Files are grouped by concern:

| Folder | What's inside |
|--------|---------------|
| 📄 [`kustomization.yaml`](./kustomization.yaml) | The entrypoint: resources, the `hermes-params` single-source config, and `replacements` (image tags, GCP project ID, domain) |
| ⚙️ [`configmaps/`](./configmaps) | Non-secret config — runtime env, startup scripts, and the read-only tool policy |
| 🔑 [`secrets/`](./secrets) | `${VAR}` Secret **templates** (dashboard auth, GitHub App key, Google OAuth token) — never real values |
| 📦 [`workloads/`](./workloads) | The `StatefulSet`, `Service`, and Traefik `IngressRoute` |
| 🔀 [`hermes-service-account/`](./hermes-service-account) | Dedicated ServiceAccount + cluster-wide **read-only** RBAC (the hard backstop) |
| 🌉 [`bridge/`](./bridge) | Python sources: the Claude Code bridge, the GCP MCP auth bridge, and helpers/tests |
| 🧩 [`skills/`](./skills) | Declarative Hermes `SKILL.md` content mounted into the agent |
| 🚦 [`traefik/`](./traefik) | Install the Traefik v3 ingress controller (chart-pinned CRDs) that serves the `IngressRoute` |

## 📦 What gets deployed

| Component | Image | Purpose |
|---|---|---|
| 🧠 hermes | `nousresearch/hermes-agent:v2026.7.20` | Gateway + dashboard (`8642` API, `9119` UI) |
| 🔌 claude-bridge | `node:22-bookworm-slim` + `@anthropic-ai/claude-code@latest` | Local Hermes-to-Claude bridge in front of the `claude` CLI (port `18181`) |
| 💾 state | PVC `agent-state` | Memory, skills, config, workspace |

Image and update policy:

- Container images stay pinned.
- Claude Code is installed from the current npm release at pod start and refreshed every 24h inside the bridge container (`CLAUDE_CODE_UPDATE_INTERVAL_SECONDS=86400`).
- The bridge executes `/opt/data/claude-code/current/bin/claude`, an atomically-swapped symlink to the newest verified install.
- Override the npm spec with `CLAUDE_CODE_NPM_SPEC` to pin/rollback, e.g. `@anthropic-ai/claude-code@2.1.167`.

Model ownership:

- Production defaults to `claude-opus-4-8` through `CLAUDE_CODE_PROXY_MODEL`, but is **not limited to it**: `CLAUDE_CODE_PASS_MODEL: "true"` makes the bridge honor any Claude model ID a client requests, and `/v1/models` advertises the full set (`CLAUDE_CODE_MODELS`) so the dashboard model picker is populated.
- `CLAUDE_CODE_PROXY_MODEL` is only the fallback used when a request omits `model`; keep `HERMES_DEFAULT_MODEL`, the runtime script fallback, and the Python bridge fallback aligned with it.
- Existing deployments can keep a stale model in `/opt/data/config.yaml` on the PVC because the init script preserves dashboard changes with `setdefault`; changing the default model for an already-running environment requires updating that PVC config or changing it through the dashboard.
- The GCP MCP auth bridge, OAuth Secret, IAM roles, `.mcp.json`, and MCP tool allow-list are independent of model selection and should not be changed for a model-only rollback.

## ⚙️ Configure once (single source of truth)

All per-deployment values live in one place — the `hermes-params` block in
[`kustomization.yaml`](./kustomization.yaml). Set them once; `kubectl apply -k .`
fans them out to every manifest via Kustomize `replacements`:

| Parameter | Rendered into |
|---|---|
| `GCP_PROJECT_ID` | `HERMES_GCP_PROJECT_ID`, `GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`, `GCP_PROJECT_ID` across both env ConfigMaps |
| `HERMES_DOMAIN` | the `Host()` rule in all three Traefik `IngressRoute` routes |

```yaml
# kustomization.yaml — edit these two lines only
- name: hermes-params
  literals:
  - GCP_PROJECT_ID=your-gcp-project-id
  - HERMES_DOMAIN=hermes.saqlainmushtaq.com
```

Preview the fully-rendered manifests before applying:

```bash
kubectl kustomize .        # or: kubectl apply -k .
```

## 🧭 Architecture and operating model

Hermes and Claude Code serve different purposes and are deliberately combined:

- **Hermes Agent** provides the persistent SRE workspace, dashboard, sessions,
  skills, schedules, and operator-facing API.
- **The Hermes bridge** is the local Hermes-to-Claude bridge in the `claude-bridge`
  sidecar. It converts Hermes requests into controlled Claude Code CLI invocations.
- **Claude Code CLI** provides the model execution and MCP client runtime. It can reason
  across Kubernetes state, repository history, CI results, and screenshots while remaining
  inside the configured tool policy.
- **Guardrails** are enforced in layers: Claude allow/deny lists, MCP server read-only
  modes, GitHub App permissions, Kubernetes RBAC, isolated credential mounts, and operator
  approval for any future write path.

```text
Dashboard / API
          |
          v
     Hermes Agent
  sessions, skills, dashboard,
  memory, Hermes MCP config
      |             |
      |             +-- Google Cloud MCP over HTTPS/OAuth
      |                 Logging + Monitoring + Trace
      |                 authenticated as hermes-agent@example.com
          |
          v
 Hermes Claude bridge (localhost:18181)
          |
          v
    Claude Code CLI
      |     |      |
      |     |      +--------- Google Cloud MCP over HTTPS/OAuth
      |     |                 same read-only GCP servers for Hermes sessions
      |     +---------------- GitHub MCP over stdio (read-only GitHub App)
      +---------------------- approved kubectl inspection commands (read-only RBAC)
```

This combination is intended to behave like a lead SRE investigation assistant—not an
autonomous production operator. It gathers evidence, correlates signals, proposes likely
root causes, links the supporting artifacts, and recommends next steps. Humans retain
authority over deployments, configuration changes, incident communications, and all other
writes.

### SRE, DevOps, and QA use cases

- Correlate a failing GitHub Actions run with the responsible commit, pull request,
  Kubernetes rollout, pod events, and logs.
- Trace crash loops, readiness failures, resource pressure, ingress problems, and service
  degradation back to configuration or application changes.
- Compare deployed revisions with repository history and identify likely regression
  windows without modifying either system.
- Help QA connect a reproducible failure, screenshot, test result, or environment symptom
  to the relevant service, code path, pull request, and CI evidence.
- Summarize incident evidence for engineers and provide safe diagnostic commands or
  remediation proposals for human review.

## 🐙 GitHub MCP: production read-only design

The deployment uses the official `github/github-mcp-server` binary as a local stdio MCP
server. It does not expose `gh`, arbitrary GitHub REST/GraphQL calls, or a reusable PAT to
the agent.

> ✅ **Optional.** The `hermes-agent-github-app` Secret (and the `hermes-agent-google-oauth` one)
> are mounted **`optional: true`**, so the pod runs fine **without** GitHub/GCP MCP — only
> `hermes-agent-secrets` is required. Add the App Secret later to enable this; no redeploy needed.

| Control | Production behavior |
|---|---|
| MCP server | Official GitHub MCP Server, latest release resolved at runtime, SHA-256 verified against the release checksums |
| Transport | Local stdio from Claude Code to `/github-mcp/start-github-mcp.sh` |
| Identity | Organization-owned GitHub App `hermes-readonly` |
| Repository scope | `your-github-org` organization, all current and future repositories |
| GitHub permissions | Read-only Actions, Checks, Contents, Deployments, Metadata, Pull requests, and Commit statuses |
| Toolsets | `repos`, `pull_requests`, and `actions` only |
| Runtime enforcement | `GITHUB_READ_ONLY=1`; Claude permits only `mcp__github-sre-readonly__*` |
| Credential lifetime | A short App JWT is exchanged for a fresh one-hour installation token per MCP process |
| Credential storage | App private key in Kubernetes Secret `hermes-agent-github-app`, mounted read-only with mode `0400` |
| Webhooks and user OAuth | Disabled; no event subscriptions and no user authorization flow |

The resulting tool surface supports repository search, branches, tags, releases, commits,
file reads, pull-request reads, workflow/run inspection, job-log reads, and related
diagnostics. It intentionally provides no create, update, comment, merge, dispatch, rerun,
cancel, workflow-edit, secret-read, or repository-administration tools.

Repository files, PR descriptions, commit messages, workflow logs, and job output are
untrusted input. Instructions found inside them must never override the system prompt,
tool policy, credential boundaries, or operator approval requirements.

## ☁️ Google Cloud MCP observability extension

Google Cloud MCP access is configured in two layers. Hermes stores the authoritative
server definitions under `mcp_servers` in `/opt/data/config.yaml` and the dashboard shows
them under `/mcp`. The Claude Code bridge also declares the same read-only HTTP MCP
servers in `/workspace/devops-agent/.mcp.json` so Claude sessions can see
and call the Google tools.

## 🔐 GCP MCP authentication

The in-pod auth bridge ([`bridge/gcp_mcp_auth_bridge.py`](./bridge/gcp_mcp_auth_bridge.py)) fronts
the Google Cloud MCP endpoints on `127.0.0.1:19190` and injects a fresh Google access token, so
Claude and Hermes never run the (broken-for-Google) interactive MCP OAuth flow. It obtains that
token one of two ways — **pick one**:

### ✅ Option A — Workload Identity (recommended)

Keyless and GKE-native. Bind the pod's Kubernetes ServiceAccount to a **read-only Google service
account**; the bridge then fetches auto-rotating tokens from the GKE metadata server. No offline
token, no client secret, no human identity to manage. The cluster already has Workload Identity
enabled (`--workload-metadata=GKE_METADATA`; see [`../gcp`](../gcp)).

```bash
export PROJECT_ID=your-gcp-project-id
export GSA=hermes-mcp-readonly

# 1) A dedicated read-only Google service account
gcloud iam service-accounts create "$GSA" --project="$PROJECT_ID" \
  --display-name="Hermes read-only GCP MCP"

# 2) Grant ONLY project-scoped read-only observability roles
for role in roles/mcp.toolUser roles/logging.viewer roles/logging.privateLogViewer \
            roles/monitoring.viewer roles/cloudtrace.user roles/cloudsql.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${GSA}@${PROJECT_ID}.iam.gserviceaccount.com" --role="$role"
done

# 3) Let the Kubernetes SA impersonate it (Workload Identity binding)
gcloud iam service-accounts add-iam-policy-binding \
  "${GSA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[devops-agent/hermes-agent]"

# 4) Map the KSA to the GSA
kubectl annotate serviceaccount hermes-agent -n devops-agent \
  iam.gke.io/gcp-service-account="${GSA}@${PROJECT_ID}.iam.gserviceaccount.com" --overwrite
```

Then set **`GCP_MCP_WORKLOAD_IDENTITY: "true"`** in
[`configmaps/configmap-claude-bridge-env.yaml`](./configmaps/configmap-claude-bridge-env.yaml)
and leave `GOOGLE_MCP_OAUTH_REFRESH_TOKEN` unset. The `hermes-agent-google-oauth` Secret is **not
needed** in this mode.

### ➕ Option B — OAuth refresh-token app (additional, not recommended)

For clusters without Workload Identity. It authenticates as a Workspace/OAuth **user identity**
(`hermes-agent@example.com`) using a long-lived **offline refresh token** stored in the
`hermes-agent-google-oauth` Secret. Trade-offs: a human-style identity, an extra OAuth web client
+ secret, and a token you must guard and rotate. Seed `GOOGLE_MCP_OAUTH_REFRESH_TOKEN` (the bridge
auto-selects this mode); full setup is in **[Durable auth: in-pod auth bridge](#durable-auth-in-pod-auth-bridge-option-b)** below.

> 🛡️ **Read-only IAM is the real guardrail either way.** Grant only the roles listed below (to the
> Workload Identity service account for Option A, or the OAuth user for Option B), and never add
> `gcloud`, Google API clients, or service-account **key files** to the pod.

Use these read-only remote MCP endpoints:

| Signal | Remote MCP endpoint | Intended SRE use |
|---|---|---|
| Cloud Logging | `https://logging.googleapis.com/mcp` | GKE workload logs, load-balancer logs, Cloud Armor policy decisions, audit evidence, and cross-service error correlation |
| Cloud Monitoring | `https://monitoring.googleapis.com/mcp` | Time series, PromQL range queries, alert-policy inspection, saturation, latency, availability, and capacity analysis |
| Cloud Trace | `https://cloudtrace.googleapis.com/mcp` | Trace lookup, service dependency analysis, slow-span investigation, and correlation of application or Cloud SQL latency |

Under **Option A** the Google identity is the read-only **service account** bound via Workload
Identity (`hermes-mcp-readonly@…`) — no human identity involved. Under **Option B** it is the
Workspace/OAuth user `hermes-agent@example.com` (not a Google Cloud IAM service-account address
and not a Kubernetes ServiceAccount); treat that as a dedicated non-human SRE identity: MFA
enforced, no mailbox workflow, no personal use, no broad admin roles, and project-scoped
read-only IAM only.

Production project defaults are exposed to both `hermes` and `claude-bridge` as
environment variables so GCP MCP prompts do not need to ask for the project ID:

```text
HERMES_GCP_PROJECT_ID=your-gcp-project-id
GOOGLE_CLOUD_PROJECT=your-gcp-project-id
GCLOUD_PROJECT=your-gcp-project-id
GCP_PROJECT_ID=your-gcp-project-id
```

These values are identifiers only. They are not Google credentials and do not grant access
without the existing OAuth token plus IAM grants for `hermes-agent@example.com`.

Minimum authorization target:

- `roles/mcp.toolUser`, required by Google Cloud MCP for `mcp.tools.call`;
- `roles/logging.viewer`;
- `roles/logging.privateLogViewer`, only because SRE troubleshooting needs private GKE,
  load-balancer, and Cloud Armor log fields;
- `roles/monitoring.viewer`;
- `roles/cloudsql.viewer`, required for Cloud SQL instance metadata when reading Cloud SQL
  CPU and memory time series through Monitoring;
- `roles/cloudtrace.user`;
- resource scope restricted to approved production projects and approved log views;
- no Logging Admin, Monitoring Editor/Admin, Trace Admin, project Viewer/Editor/Owner,
  API keys, service-account keys, metadata-token inspection, Cloud SQL Client, or general
  `gcloud` access.

Read-only is enforced in three places:

1. Google Cloud IAM grants only viewer/user roles to the chosen GCP identity (the Workload
   Identity service account for Option A, or the OAuth user for Option B).
2. Claude Code permissions allow only the exact read-only GCP MCP tool names listed below;
   do not use broad `mcp__gcp-*__*` allow patterns.
3. Operators must validate both positive reads and negative write absence after every MCP
   or OAuth change.

The Google OAuth consent/token metadata can expose provider-defined API scopes that do not
map one-to-one to the final SRE capability. Do not rely on OAuth scope labels as the
guardrail. The guardrail is the combination of read-only IAM, explicit MCP tool allow-list,
and no in-pod `gcloud`/metadata/API-client path.

Temporary setup-only roles:

- `roles/oauthconfig.editor` (`OAuth Config Editor (Beta)`) is needed only to create or
  update the OAuth web client and retrieve/create its secret.
- `roles/iam.serviceAccountViewer` (`View Service Accounts`) is only needed because the
  Google Auth Platform UI loads service-account metadata while creating a client.
- `roles/serviceusage.serviceUsageViewer` (`Service Usage Viewer`) is only needed for
  Google Cloud Console/API visibility while checking enabled APIs.

After the OAuth web client is created, `hermes-agent-google-oauth` is populated with the
client ID, client secret, and offline refresh token, and the token-bridge health/read tests
pass, remove those setup-only roles from `hermes-agent@example.com`. Runtime MCP access should
continue to rely only on `roles/mcp.toolUser` plus the project-scoped observability roles
listed above.

### Durable auth: in-pod auth bridge (Option B)

> ⚡ **This is the supported auth path.** Do not use interactive `hermes mcp login` /
> `claude mcp login` for the production GCP MCP servers; those flows do not produce
> durable auth against Google (see why).

**Why the old flow broke:** Claude Code and Hermes run the standard MCP OAuth (PKCE)
flow, which never sends Google's proprietary `access_type=offline` parameter. Google
only returns a **refresh token** when that parameter is present, so every interactive
login produced an *access-token-only* grant (`expires_in: 3599`, no refresh token). After
one hour there was nothing to refresh with, so the agent reported *"token expired, needs
re-authorization"* — and re-authenticating just bought another hour. Neither client
exposes a way to add `access_type=offline`, so this is unfixable inside their OAuth flow.

**The fix:** a tiny loopback auth bridge (`gcp_mcp_auth_bridge.py`) runs in the
`claude-bridge` sidecar. It holds one long-lived offline refresh token for
`hermes-agent@example.com`, mints fresh access tokens on demand (caching until ~2 min before
expiry), and injects `Authorization: Bearer` into requests forwarded to the real
`*.googleapis.com/mcp` endpoints. Both Hermes (`config.yaml`) and the Claude bridge
(`.mcp.json`) point at `http://127.0.0.1:19190/{logging,monitoring,trace}` and do **no
OAuth at all**. Pod containers share a network namespace, so one proxy serves both.
The bridge forwards only `GET` and `POST`; destructive HTTP methods such as `DELETE` are
rejected before they can reach Google.

Identity stays `hermes-agent@example.com` and IAM stays read-only — unchanged. This adds an
outbound call to `oauth2.googleapis.com` but **no** `gcloud`, SA key, ADC, or
metadata-server access.

**One-time setup (the only manual auth, ever):**

1. On a laptop, signed into Chrome as `hermes-agent@example.com`, obtain the refresh token:

   ```bash
   export GOOGLE_MCP_OAUTH_CLIENT_ID='YOUR_OAUTH_CLIENT_ID.apps.googleusercontent.com'
   export GOOGLE_MCP_OAUTH_CLIENT_SECRET='<web client secret>'
   python3 kubernetes/bridge/get-gcp-mcp-refresh-token.py
   # approve once -> prints GOOGLE_MCP_OAUTH_REFRESH_TOKEN
   ```

   The script uses `access_type=offline` + `prompt=consent` and the already-registered
   `http://127.0.0.1:19191/callback` redirect URI. If it prints "No refresh_token
   returned", revoke the prior grant at https://myaccount.google.com/permissions and
   rerun.

2. Store all three values in the dedicated Secret:

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   kubectl -n devops-agent create secret generic hermes-agent-google-oauth \
     --from-literal=GOOGLE_MCP_OAUTH_CLIENT_ID="$GOOGLE_MCP_OAUTH_CLIENT_ID" \
     --from-literal=GOOGLE_MCP_OAUTH_CLIENT_SECRET="$GOOGLE_MCP_OAUTH_CLIENT_SECRET" \
     --from-literal=GOOGLE_MCP_OAUTH_REFRESH_TOKEN="<printed value>" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

3. Apply and roll:

   ```bash
   kubectl -n devops-agent apply -k kubernetes
   kubectl -n devops-agent rollout restart statefulset/hermes-agent
   kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=420s
   ```

4. Verify the bridge is up and a real read works end-to-end:

   ```bash
   # bridge health (loopback)
   kubectl -n devops-agent exec hermes-agent-0 -c claude-bridge -- \
     curl -fsS http://127.0.0.1:19190/healthz

   # real read through the bridge chain
   kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
     /opt/hermes/bin/hermes mcp test gcp-logging-sre-readonly
   ```

   `roles/mcp.toolUser` plus the read-only observability roles must already be granted to
   `hermes-agent@example.com` (they were, since the old flow returned reads for an hour). No
   IAM change is needed for this fix.

**Refresh-token lifetime:** indefinite while the OAuth consent screen is **Internal**
(Workspace) or **In production**. It only needs re-seeding if revoked or if the client
secret is rotated. (In "Testing" publishing status Google expires refresh tokens after 7
days — confirm the consent screen is Internal/In production.)

### Production deployment sequence for GCP MCP

Use this sequence for production. Do **not** use `hermes mcp login`, `claude mcp add`, or
`claude mcp login` for the GCP MCP servers in production; those interactive flows create
one-hour access-token-only grants and eventually fail with `token expired` /
`requires re-authorization`.

1. Create one Google OAuth web client for the Hermes GCP MCP auth bridge.

   Use these authorized redirect URIs:

   ```text
   http://127.0.0.1:19191/callback
   ```

   `19191` is used only by `bridge/get-gcp-mcp-refresh-token.py` on an operator laptop to capture
   the one-time OAuth callback. The production pod does not expose this callback port and
   does not run interactive browser OAuth.

2. Confirm `hermes-agent@example.com` has only the runtime read-only roles:

   - `roles/mcp.toolUser`;
   - `roles/logging.viewer`;
   - `roles/logging.privateLogViewer`;
   - `roles/monitoring.viewer`;
   - `roles/cloudsql.viewer`;
   - `roles/cloudtrace.user`.

   Remove the setup-only roles after the OAuth client and Secret are ready:

   - `roles/oauthconfig.editor`;
   - `roles/iam.serviceAccountViewer`;
   - `roles/serviceusage.serviceUsageViewer`.

3. Generate the offline refresh token once from an operator laptop signed into Chrome as
   `hermes-agent@example.com`:

   ```bash
   cd $HOME/hermes-claude-code-bridge
   export GOOGLE_MCP_OAUTH_CLIENT_ID="<google-oauth-web-client-id>"
   export GOOGLE_MCP_OAUTH_CLIENT_SECRET="<google-oauth-web-client-secret>"

   python3 kubernetes/bridge/get-gcp-mcp-refresh-token.py
   ```

   The script deliberately sends `access_type=offline` and `prompt=consent`, which is what
   Google needs before it returns a refresh token. Store the printed
   `GOOGLE_MCP_OAUTH_REFRESH_TOKEN` in the approved production secret store before using
   it. Never commit it.

4. Store the OAuth client credentials and refresh token in the dedicated Google OAuth
   Secret. Do not place these keys in `hermes-agent-secrets`; that Secret is reserved for
   Hermes runtime keys used by the API, dashboard, and Claude bridge.

   **Do not recreate `hermes-agent-secrets` when adding Google OAuth.** Replacing that
   Secret with only `GOOGLE_MCP_OAUTH_*` keys removes `CLAUDE_CODE_PROXY_API_KEY` and
   causes `init-hermes-config` to crash with `KeyError: 'CLAUDE_CODE_PROXY_API_KEY'`.

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   export GOOGLE_MCP_OAUTH_CLIENT_ID="<google-oauth-web-client-id>"
   export GOOGLE_MCP_OAUTH_CLIENT_SECRET="<google-oauth-web-client-secret>"
   export GOOGLE_MCP_OAUTH_REFRESH_TOKEN="<google-oauth-refresh-token>"

   kubectl -n devops-agent create secret generic hermes-agent-google-oauth \
     --from-literal=GOOGLE_MCP_OAUTH_CLIENT_ID="$GOOGLE_MCP_OAUTH_CLIENT_ID" \
     --from-literal=GOOGLE_MCP_OAUTH_CLIENT_SECRET="$GOOGLE_MCP_OAUTH_CLIENT_SECRET" \
     --from-literal=GOOGLE_MCP_OAUTH_REFRESH_TOKEN="$GOOGLE_MCP_OAUTH_REFRESH_TOKEN" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

   Confirm that the runtime Secret still has its required keys and that the Google OAuth
   Secret has only OAuth keys. This prints key names only, never values:

   ```bash
   kubectl -n devops-agent get secret hermes-agent-secrets \
     -o go-template='{{range $k, $_ := .data}}{{printf "%s\n" $k}}{{end}}' | sort

   kubectl -n devops-agent get secret hermes-agent-google-oauth \
     -o go-template='{{range $k, $_ := .data}}{{printf "%s\n" $k}}{{end}}' | sort
   ```

   Required `hermes-agent-secrets` keys:

   - `API_SERVER_KEY`
   - `CLAUDE_CODE_PROXY_API_KEY`
   - `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`
   - `HERMES_DASHBOARD_BASIC_AUTH_SECRET`
   - `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`

   Required `hermes-agent-google-oauth` keys:

   - `GOOGLE_MCP_OAUTH_CLIENT_ID`
   - `GOOGLE_MCP_OAUTH_CLIENT_SECRET`
   - `GOOGLE_MCP_OAUTH_REFRESH_TOKEN`

5. Apply the manifests and roll Hermes:

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   kubectl -n devops-agent apply -k $HOME/hermes-claude-code-bridge/kubernetes
   kubectl -n devops-agent rollout restart statefulset/hermes-agent
   kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=420s
   ```

6. Remove stale local Claude MCP entries if they were created during the old
   `claude mcp add --scope local` workflow. Local-scope entries shadow the project
   `.mcp.json` proxy entries and can force Claude Code back onto the broken direct OAuth
   path.

   ```bash
   kubectl -n devops-agent exec hermes-agent-0 -c claude-bridge -- sh -lc '
   cd /workspace/devops-agent
   /opt/data/claude-code/current/bin/claude mcp remove gcp-logging-sre-readonly -s local || true
   /opt/data/claude-code/current/bin/claude mcp remove gcp-monitoring-sre-readonly -s local || true
   /opt/data/claude-code/current/bin/claude mcp remove gcp-trace-sre-readonly -s local || true
   '
   ```

   The remaining GCP MCP entries should come from the project `.mcp.json` and should point
   to `http://127.0.0.1:19190/...`.

7. Verify the pod and auth bridge are healthy:

   ```bash
   kubectl -n devops-agent get pod hermes-agent-0 \
     -o jsonpath='{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}={.ready},restart={.restartCount}{"\n"}{end}'

   kubectl -n devops-agent exec hermes-agent-0 -c claude-bridge -- \
     curl -fsS http://127.0.0.1:19190/healthz
   ```

   Expected:

   ```text
   Running
   claude-bridge=true,restart=0
   hermes=true,restart=0
   ok
   ```

8. Verify the three Hermes MCP servers are declared, enabled, and routed through the
   loopback auth bridge:

   ```bash
   kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
     /opt/hermes/bin/hermes mcp list
   ```

   Expected servers:

   | Hermes MCP server | Endpoint | Tools |
   |---|---|---|
   | `gcp-logging-sre-readonly` | `http://127.0.0.1:19190/logging` | 6 selected |
   | `gcp-monitoring-sre-readonly` | `http://127.0.0.1:19190/monitoring` | 9 selected |
   | `gcp-trace-sre-readonly` | `http://127.0.0.1:19190/trace` | 2 selected |

9. Verify each Hermes MCP server connects through the bridge:

   ```bash
   kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
     /opt/hermes/bin/hermes mcp test gcp-logging-sre-readonly

   kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
     /opt/hermes/bin/hermes mcp test gcp-monitoring-sre-readonly

   kubectl -n devops-agent exec hermes-agent-0 -c hermes -- \
     /opt/hermes/bin/hermes mcp test gcp-trace-sre-readonly
   ```

10. Verify the Claude-side bridge exposes the same GCP MCP tools to Claude sessions:

   ```bash
   kubectl -n devops-agent exec hermes-agent-0 -c claude-bridge -- sh -lc '
   cd /workspace/devops-agent
   /opt/data/claude-code/current/bin/claude mcp list
   curl -fsS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" \
     "http://${CLAUDE_CODE_PROXY_HOST}:${CLAUDE_CODE_PROXY_PORT}/config" |
     jq ".allowed_tools"
   '
   ```

   Expected Claude-side project MCP servers:

   - `gcp-logging-sre-readonly`
   - `gcp-monitoring-sre-readonly`
   - `gcp-trace-sre-readonly`

   Expected proxy allow-list entries are exact read-only tool names only:

   - `mcp__gcp-logging-sre-readonly__list_log_entries`
   - `mcp__gcp-logging-sre-readonly__list_log_names`
   - `mcp__gcp-logging-sre-readonly__get_bucket`
   - `mcp__gcp-logging-sre-readonly__list_buckets`
   - `mcp__gcp-logging-sre-readonly__get_view`
   - `mcp__gcp-logging-sre-readonly__list_views`
   - `mcp__gcp-monitoring-sre-readonly__list_timeseries`
   - `mcp__gcp-monitoring-sre-readonly__query_range`
   - `mcp__gcp-monitoring-sre-readonly__get_alert_policy`
   - `mcp__gcp-monitoring-sre-readonly__list_alert_policies`
   - `mcp__gcp-monitoring-sre-readonly__get_alert`
   - `mcp__gcp-monitoring-sre-readonly__list_alerts`
   - `mcp__gcp-monitoring-sre-readonly__list_metric_descriptors`
   - `mcp__gcp-monitoring-sre-readonly__list_dashboards`
   - `mcp__gcp-monitoring-sre-readonly__get_dashboard`
   - `mcp__gcp-trace-sre-readonly__list_traces`
   - `mcp__gcp-trace-sre-readonly__get_trace`

   The allow-list must not contain:

   - `mcp__gcp-logging-sre-readonly__*`
   - `mcp__gcp-monitoring-sre-readonly__*`
   - `mcp__gcp-trace-sre-readonly__*`

   Confirm the pod, Claude-side Monitoring auth, and Cloud SQL metric reads:

   ```bash
   export KUBECONFIG=$HOME/.kube/config

   kubectl -n devops-agent get pod hermes-agent-0 \
     -o jsonpath='{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}={.ready}{"\n"}{end}'

   kubectl -n devops-agent exec hermes-agent-0 -c claude-bridge -- sh -lc '
   cd /workspace/devops-agent
   /opt/data/claude-code/current/bin/claude mcp list |
     sed -n "/gcp-monitoring-sre-readonly/p"
   '

   kubectl -n devops-agent exec -it hermes-agent-0 -c claude-bridge -- sh -lc '
   cd /workspace/devops-agent
   /opt/data/claude-code/current/bin/claude --model claude-opus-4-8 -p --max-budget-usd 0.75 "
   Use only the gcp-monitoring-sre-readonly MCP tools.
   For project your-gcp-project-id, read recent Cloud SQL CPU utilization and memory utilization time series for the last 10 minutes.
   Do not fabricate.
   Reply with exactly:
   CPU=<data|empty|error: short reason>; MEMORY=<data|empty|error: short reason>.
   "
   '
   ```

   Also verify that Monitoring tool discovery and time-series reads both work. Descriptor
   discovery alone is not enough, because an OAuth/session issue can still block
   `list_timeseries`:

   ```bash
   kubectl -n devops-agent exec -it hermes-agent-0 -c claude-bridge -- sh -lc '
   cd /workspace/devops-agent
   /opt/data/claude-code/current/bin/claude --model claude-opus-4-8 -p --max-budget-usd 0.75 "
   Use only gcp-monitoring-sre-readonly MCP tools.
   For project your-gcp-project-id:
   1. list metric descriptors filtered to cloudsql.googleapis.com/database/cpu;
   2. list time series for cloudsql.googleapis.com/database/cpu/utilization over the last 10 minutes.
   Reply exactly:
   DESCRIPTORS=<data|empty|error: short reason>; TIMESERIES=<data|empty|error: short reason>.
   Do not use memory, kubectl, logging, or gcloud.
   "
   '
   ```

   If `claude mcp list` shows Monitoring as connected but the prompt reports
   `token expired` or `requires re-authorization`, run a fresh Claude-side logout/login
   for `gcp-monitoring-sre-readonly`, then start a new Hermes session so the tool
   registry is rediscovered.

11. Verify from Hermes chat with bounded, read-only prompts:

   ```text
   Using only the GCP Logging read-only connector, show Cloud Armor deny decisions for
   the last 30 minutes. Return counts and sample sanitized log names only. Do not fetch
   secrets, credentials, request bodies, or customer data.
   ```

   ```text
   Using only the GCP Monitoring read-only connector, summarize current GKE CPU, memory,
   restart, and availability signals for the production cluster over the last 30 minutes.
   Do not create, update, or delete alerts or dashboards.
   ```

   ```text
   Using only the GCP Trace read-only connector, list the slowest service spans in the
   last 30 minutes and correlate them with Cloud SQL query spans if present. Do not write
   trace tasks or modify trace scopes.
   ```

### Kubernetes auth model for Google MCP

There are two separate identities in the production Hermes pod:

| Layer | Identity | Purpose | Where it lives |
|---|---|---|---|
| Kubernetes API | `system:serviceaccount:devops-agent:hermes-agent` | Read-only cluster inspection: pods, events, logs, workloads, services, ingress, non-secret RBAC visibility | Kubernetes ServiceAccount token mounted by GKE |
| Google MCP OAuth | `hermes-agent@example.com` | Read-only Google Cloud Logging, Monitoring, and Trace MCP access | Offline refresh token in Kubernetes Secret `hermes-agent-google-oauth`; short-lived access tokens cached only in the loopback auth bridge memory |

Do not confuse these. `hermes-agent@example.com` is **not** a Kubernetes ServiceAccount and is
not mounted into the pod as a Google key. It authenticates the Google MCP servers through
the loopback auth bridge, which uses the Secret refresh token to mint normal short-lived
Google access tokens. The deployment still avoids Google service-account keys,
metadata-token tooling, `gcloud`, and Cloud SQL Client in the pod.

Live production config paths:

```text
/opt/data/config.yaml
/workspace/devops-agent/.mcp.json
/workspace/devops-agent/.claude/settings.local.json
/app/gcp_mcp_auth_bridge.py
```

Verify current production auth/config state:

```bash
export KUBECONFIG=$HOME/.kube/config

kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=120s

kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/bin/hermes mcp list

kubectl -n devops-agent exec statefulset/hermes-agent -c hermes -- \
  /opt/hermes/bin/hermes mcp test gcp-logging-sre-readonly
```

Expected after manifest apply and rollout:

- `curl http://127.0.0.1:19190/healthz` returns `ok` from the `claude-bridge` container;
- the three `gcp-*` Hermes MCP servers show as enabled in `hermes mcp list`;
- `hermes mcp test` succeeds for Logging, Monitoring, and Trace;
- the Hermes MCP endpoints show `http://127.0.0.1:19190/{logging,monitoring,trace}`;
- Hermes chat can use only the selected read-only tools declared in `/opt/data/config.yaml`.

Expected after full Claude bridge validation:

- `claude mcp list` in the `claude-bridge` container shows all three `gcp-*` servers as
  connected through `http://127.0.0.1:19190/...`;
- Hermes sessions can call the GCP Logging, Monitoring, and Trace MCP tools
  against project `your-gcp-project-id`;
- empty query results are acceptable, but IAM or OAuth failures are not.

Production verification completed on 2026-06-24:

- `hermes-agent-0` reached `2/2 Running` with zero restarts after restoring the runtime
  Secret shape;
- Hermes MCP tests connected successfully to Logging, Monitoring, and Trace;
- Logging exposed 6 selected tools, Monitoring exposed 9 selected tools, and Trace exposed
  2 selected tools;
- the Hermes SRE agent confirmed real read-only results from
  `your-gcp-project-id` for all three GCP MCP integrations.

If a GCP MCP server asks for `mcp_servers.<name>.oauth.client_id`, `client_secret`, or a
browser login, the old direct OAuth path is active and should be treated as a
misconfiguration. Ensure `hermes-agent-google-oauth` contains
`GOOGLE_MCP_OAUTH_CLIENT_ID`, `GOOGLE_MCP_OAUTH_CLIENT_SECRET`, and
`GOOGLE_MCP_OAUTH_REFRESH_TOKEN`, confirm `/opt/data/config.yaml` and
`/workspace/devops-agent/.mcp.json` point to `http://127.0.0.1:19190/...`, remove stale
local Claude MCP entries, then roll the StatefulSet.

The Google MCP servers use OAuth 2.0 and IAM. Their addition must follow the same layered
pattern as GitHub: separately named MCP servers, exact read-only tool allow-lists,
read-only IAM, credential isolation, bounded query windows/result counts, redaction of
secrets and personal data, audit logging, and live negative tests proving write tools are
absent or denied. See the official Google documentation for
[MCP authentication](https://docs.cloud.google.com/mcp/authenticate-mcp),
[Cloud Logging MCP](https://docs.cloud.google.com/logging/docs/use-logging-mcp),
[Cloud Monitoring MCP](https://docs.cloud.google.com/monitoring/api/ref_v3_mcp/mcp), and
[Cloud Trace MCP](https://docs.cloud.google.com/trace/docs/reference/mcp/mcp/tools_list/list_traces).

---

# 🚀 Deployment steps

Follow these in order.

> 🧱 **Prerequisites:** a GKE cluster and a TLS ingress controller.
> - Need a cluster? Provision a cost-optimized one with [`../gcp`](../gcp).
> - Ingress: install **Traefik v3** with [`./traefik`](./traefik) — the `IngressRoute` in this deployment routes through it.

## Step 1 — Set target cluster and authenticate

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-west1"
export CLUSTER_NAME="your-gke-cluster"
export NAMESPACE="devops-agent"
```

Authenticate using **either** option.

**Option A — gcloud (generates kubeconfig automatically):**

```bash
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID"
```

**Option B — existing kubeconfig file:** point `KUBECONFIG` at your operator-only
cluster credentials file (kept outside this repo; never commit its path or contents):

```bash
export KUBECONFIG="$HOME/.kube/config"
```

Confirm the active context before continuing:

```bash
kubectl config current-context
```

## Step 2 — Create the namespace

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

## Step 3 — Generate the dashboard password and hash

> ⚠️ **Important: where this password is stored**
>
> The command below only stores the generated password in the `HERMES_DASHBOARD_PASSWORD`
> environment variable of **your current terminal session**. It is not written to
> a file, Git, Kubernetes, Docker, or a secret manager automatically.
>
> Before closing this terminal, copy the plaintext value into the approved
> production secret manager. If you lose it, you cannot recover it from the hash;
> generate a new password and recreate the Kubernetes secret.

Generate a strong password:

```bash
export HERMES_IMAGE='nousresearch/hermes-agent:v2026.7.20'
docker pull "$HERMES_IMAGE"

export HERMES_DASHBOARD_PASSWORD="$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits + "-_+=") for _ in range(56)))')"
printf 'Dashboard password generated. Store it in the approved production secret manager before continuing.\n'
```

Save the plaintext password now (for example, paste it into the approved password/secret manager):

```bash
echo "$HERMES_DASHBOARD_PASSWORD"
```

Then hash the password with the **exact** Hermes image. Hermes uses **scrypt** internally — generic hashers (`sha256`, `bcrypt`) produce invalid hashes that silently reject every login.

Only the hash goes into the Kubernetes secret in Step 4; the plaintext password is for humans to log in to the dashboard.

```bash
export HERMES_DASHBOARD_PASSWORD_HASH="$(
  docker run --rm \
    --entrypoint /opt/hermes/.venv/bin/python \
    -e PYTHONPATH=/opt/hermes \
    -e HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
    "$HERMES_IMAGE" \
    -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))'
)"
echo "Password hash: $HERMES_DASHBOARD_PASSWORD_HASH"
```

## Step 4 — Create the Kubernetes secret

Create the live secret directly from literals (keeps plaintext out of git). Do not apply `secrets/secret.template.yaml` directly.

Run all commands in this section from an operator workstation, not from the Hermes pod:

```bash
export KUBECONFIG='$HOME/.kube/config'
export NAMESPACE='devops-agent'
export GITHUB_ORG='your-github-org'
export GITHUB_APP_ID='<numeric-app-id>'
export GITHUB_APP_PRIVATE_KEY_FILE='/secure/path/to/hermes-readonly.pem'

chmod 600 "$GITHUB_APP_PRIVATE_KEY_FILE"
kubectl config current-context
kubectl get namespace "$NAMESPACE"
```

### Create the organization-owned GitHub App

Create a separate GitHub App under **your-github-org → Settings → Developer settings →
GitHub Apps**. Do not reuse the existing Anthropic Claude App: that App has write access
to code, workflows, pull requests, issues, hooks, and other repository resources.

Configure the new App:

- **Name:** `hermes-readonly` (or another unique approved name)
- **Homepage URL:** `https://hermes.saqlainmushtaq.com`
- **Webhook:** inactive
- **User authorization:** not required
- **Repository permissions:**
  - Actions: Read-only
  - Checks: Read-only
  - Commit statuses: Read-only
  - Contents: Read-only
  - Deployments: Read-only
  - Metadata: Read-only
  - Pull requests: Read-only
- **Organization permissions:** No access
- **Account permissions:** No access
- **Installation scope:** only the `your-github-org` organization

After creating it:

1. Generate one private key and store the downloaded PEM in the approved production
   secret manager.
2. Record the numeric **App ID** from the App settings page.
3. Install the App on `your-github-org` and select **All repositories**. This includes all
   existing repositories and automatically grants the same read-only access to future
   repositories.
4. Record the numeric installation ID from the installation URL:
   `https://github.com/organizations/your-github-org/settings/installations/<INSTALLATION_ID>`.

Alternatively, discover and validate the installation from the command line. This prints
only non-secret installation metadata and never prints the JWT or installation token:

```bash
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now="$(date +%s)"
iat="$((now - 60))"
exp="$((now + 540))"
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
  "$iat" "$exp" "$GITHUB_APP_ID" | b64url)"
signature="$(printf '%s' "$header.$payload" | \
  openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_FILE" | b64url)"
app_jwt="$header.$payload.$signature"

installation_json="$(curl -fsS \
  -H "Authorization: Bearer $app_jwt" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  https://api.github.com/app/installations)"

printf '%s' "$installation_json" | jq -c \
  --arg org "$GITHUB_ORG" \
  '.[] | select(.account.login == $org) |
   {id, account: .account.login, repository_selection, permissions, events}'

export GITHUB_APP_INSTALLATION_ID="$(printf '%s' "$installation_json" | jq -er \
  --arg org "$GITHUB_ORG" \
  '.[] | select(.account.login == $org and .repository_selection == "all") | .id')"
unset app_jwt signature
```

Confirm that `repository_selection` is `all`, every permission is `read`, and `events` is
empty before creating the Kubernetes Secret.

Create the dedicated Kubernetes Secret directly; never commit the PEM or render it into a
ConfigMap:

```bash
# If the installation ID was copied from the GitHub URL instead of discovered above:
# export GITHUB_APP_INSTALLATION_ID='<numeric-installation-id>'

: "${GITHUB_APP_ID:?export GITHUB_APP_ID first}"
: "${GITHUB_APP_INSTALLATION_ID:?export GITHUB_APP_INSTALLATION_ID first}"
: "${GITHUB_APP_PRIVATE_KEY_FILE:?export GITHUB_APP_PRIVATE_KEY_FILE first}"

kubectl -n "$NAMESPACE" create secret generic hermes-agent-github-app \
  --from-literal=app-id="$GITHUB_APP_ID" \
  --from-literal=installation-id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=private-key.pem="$GITHUB_APP_PRIVATE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

For every Claude Code invocation, the trusted MCP launcher signs a short-lived GitHub App
JWT, exchanges it for a one-hour installation token, and starts the official GitHub MCP
server with `GITHUB_READ_ONLY=1` and only the `repos`, `pull_requests`, and `actions`
toolsets. No PAT or manually rotated access token is stored.

> The previous remote endpoint
> `https://api.githubcopilot.com/mcp/x/repos,pull_requests,actions/readonly` is no longer
> used by this deployment. Opening it in a browser returns `missing required Authorization
> header` because it is an authenticated MCP endpoint, not a web page.

```bash
export API_SERVER_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export CLAUDE_CODE_PROXY_API_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"

kubectl -n "$NAMESPACE" create secret generic hermes-agent-secrets \
  --from-literal=API_SERVER_KEY="$API_SERVER_KEY" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME="admin" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HERMES_DASHBOARD_PASSWORD_HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$HERMES_DASHBOARD_BASIC_AUTH_SECRET" \
  --from-literal=CLAUDE_CODE_PROXY_API_KEY="$CLAUDE_CODE_PROXY_API_KEY" \
  --from-literal=HERMES_DEFAULT_PROVIDER="claude-code-bridge" \
  --from-literal=HERMES_DEFAULT_MODEL="claude-opus-4-8" \
  --from-literal=HERMES_DEFAULT_BASE_URL="http://127.0.0.1:18181/v1" \
  --from-literal=HERMES_DEFAULT_API_MODE="chat_completions" \
  --dry-run=client -o yaml | kubectl apply -f -
```

> 📌 **Password storage summary:** plaintext password = stored by the operator in the approved secret manager and used for dashboard login; password hash = stored in Kubernetes secret `hermes-agent-secrets`; plaintext password = never stored in Git or the cluster.
>
> 🔒 **Never commit real tokens.** `secrets/secret.template.yaml` is an environment-variable template. Do **not** run `kubectl apply -f secrets/secret.template.yaml` directly; Kubernetes would accept the literal `${...}` placeholders as strings, but the deployment would get invalid secret values. Prefer the `kubectl create secret ... --from-literal` command above, or render the template with `envsubst` after exporting every required variable:
>
> ```bash
> envsubst < kubernetes/secrets/secret.template.yaml | kubectl apply -f -
> ```
>
> Store Google MCP OAuth client credentials separately in `hermes-agent-google-oauth`.
> Use `secrets/secret-google-oauth.template.yaml` or `kubectl create secret generic
> hermes-agent-google-oauth ... --dry-run=client -o yaml | kubectl apply -f -`.

## Step 5 — Apply the manifests

Runtime configuration is ConfigMap-driven. `kustomize` applies the runtime environment ConfigMaps, startup-script ConfigMaps, Claude permissions ConfigMap, declarative MCP ConfigMap, and the generated bridge implementation ConfigMap from `kubernetes/bridge/claude_code_bridge.py`; no separate manual ConfigMap apply is needed. GitHub App credentials remain in the separately mounted `hermes-agent-github-app` Secret.

```bash
kubectl apply --dry-run=server -k kubernetes >/dev/null
kubectl apply -k kubernetes
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=240s
kubectl -n "$NAMESPACE" get statefulset,pod,pvc,svc,ingressroute -o wide
```

Use the existing client-side apply ownership model shown above. Do not add
`--server-side --force-conflicts`; the StatefulSet volume claim template may already be
owned by the existing client-side field manager.

## Step 6 — Health check

```bash
kubectl exec -n "$NAMESPACE" hermes-agent-0 -c hermes -- \
  sh -lc 'curl -s localhost:8642/health'      # → {"status":"ok",...}
```

## Step 7 — Log in to the dashboard

```bash
kubectl port-forward -n "$NAMESPACE" statefulset/hermes-agent 9119:9119
# open http://localhost:9119
```

```text
URL:      https://hermes.saqlainmushtaq.com
Username: admin
Password: value stored in the approved production secret manager
```

## Step 8 — Complete Claude Code login

The Claude Code subscription login runs inside the `claude-bridge` container; state is stored on the PVC at `/home/claude`.

```bash
kubectl -n "$NAMESPACE" exec -it hermes-agent-0 -c claude-bridge -- sh
```

Inside the pod:

```bash
export HOME=/home/claude
cd /workspace/devops-agent
claude
```

Complete `/login`, then verify:

```bash
claude -p "Reply with exactly: claude auth ok"
```

## Step 8.1 — Durable agent memory and approved skill writes

Hermes keeps SRE operations read-only while allowing the Claude Code bridge to persist compact memory and approved Hermes skills across sessions. This is the only intentional local write capability in the production proxy.

Approved writable PVC paths:

```bash
/home/claude/.claude/projects/-workspace-devops-agent/memory
/opt/data/skills
```

Policy:

- `Read` and `Write` are allowed only for the memory path and Hermes skills path above.
- `Edit` and `NotebookEdit` remain denied.
- Kubernetes, GitHub, and GCP tools remain read-only.
- Memory is for durable operational facts only: approved tool inventory, stable environment notes, runbook preferences, and known guardrails.
- Skills are for `SKILL.md` operating instructions only, such as the lead DevOps/SRE greeting and capability profile.
- The approved skills source of truth in Git is `kubernetes/skills/<skill-name>/SKILL.md`; Kustomize packages those files into `hermes-agent-declarative-skills`, and startup syncs them to `/opt/data/skills/<skill-name>/SKILL.md` on the PVC.
- Runtime Skills writes may update only files under `/opt/data/skills/**`; they must not create operational scripts, credentials, API clients, kubectl wrappers, or broad automation outside `SKILL.md` content.
- Never store secrets, tokens, passwords, private keys, customer data, raw logs, screenshots, or long transcripts in memory or skills.

Verify memory and skills are writable after rollout:

```bash
export KUBECONFIG="$HOME/.kube/config"
kubectl -n devops-agent exec statefulset/hermes-agent -c claude-bridge -- \
  sh -lc 'test -d "$CLAUDE_CODE_MEMORY_DIR" && test -w "$CLAUDE_CODE_MEMORY_DIR" && echo "memory writable: $CLAUDE_CODE_MEMORY_DIR"; test -d "$HERMES_SKILLS_DIR" && test -w "$HERMES_SKILLS_DIR" && echo "skills writable: $HERMES_SKILLS_DIR"'
```

Verify the bridge policy exposes only the scoped write rule:

```bash
kubectl -n devops-agent exec statefulset/hermes-agent -c claude-bridge -- \
  sh -lc 'curl -fsS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" "http://${CLAUDE_CODE_PROXY_HOST}:${CLAUDE_CODE_PROXY_PORT}/config"' \
  | jq '.allowed_tools, .disallowed_tools'
```

Expected:

- allowed tools include `Write(//home/claude/.claude/projects/-workspace-devops-agent/memory/**)`;
- allowed tools include `Write(//opt/data/skills/**)`;
- disallowed tools still include `Edit` and `NotebookEdit`;
- disallowed tools do not include bare `Write`, because that would also block the scoped memory and skills writes.

Then ask Hermes in chat:

```text
Update your memory with this durable fact: GitHub SRE access is read-only via github-sre-readonly.
Then read it back from memory.
```

To verify the declarative lead DevOps/SRE skill landed on the PVC:

```bash
kubectl -n devops-agent exec statefulset/hermes-agent -c claude-bridge -- \
  sh -lc 'test -f "$HERMES_SKILLS_DIR/lead-devops-sre/SKILL.md" && sed -n "1,40p" "$HERMES_SKILLS_DIR/lead-devops-sre/SKILL.md"'
```

## Step 9 — Restart and validate

Restart so the gateway reloads runtime config:

```bash
kubectl -n "$NAMESPACE" rollout restart statefulset/hermes-agent
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=240s
```

Verify bridge config:

```bash
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c claude-bridge -- sh -lc \
  'curl -sS -H "Authorization: Bearer ${CLAUDE_CODE_PROXY_API_KEY}" http://127.0.0.1:18181/config'
```

Verify the declarative GitHub MCP server without printing credentials:

```bash
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c claude-bridge -- sh -lc \
  'test -n "${GITHUB_APP_ID:-}"; test -n "${GITHUB_APP_INSTALLATION_ID:-}"; test -r "$GITHUB_APP_PRIVATE_KEY_FILE"; claude mcp list'
```

The output should list `github-sre-readonly` as connected. Then test from Hermes chat:

```text
Using only the github-sre-readonly tools, read your-github-org/ci-tools and return
the latest commit SHA, title, and changed file names. Do not create, update,
comment, dispatch, rerun, cancel, merge, or modify anything.
```

The MCP configuration and launcher are mounted read-only. The private key is mounted from
the dedicated Secret and the one-hour installation token exists only in the MCP child
process environment; neither is written into the ConfigMap or workspace PVC.

For a model-independent live test, call the MCP server directly over stdio from the bridge
container. This verifies App JWT exchange, installation-token creation, access to a private
repository, and the read-only tool surface without displaying credentials:

```bash
kubectl -n "$NAMESPACE" exec hermes-agent-0 -c claude-bridge -- sh -lc '
  {
    printf "%s\n" '\''{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"hermes-verifier","version":"1.0"}}}'\''
    printf "%s\n" '\''{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'\''
    printf "%s\n" '\''{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'\''
    printf "%s\n" '\''{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_file_contents","arguments":{"owner":"your-github-org","repo":"ci-tools","path":"hermes-agent/kubernetes/README.md","ref":"refs/heads/master"}}}'\''
    sleep 4
  } | timeout 30 /github-mcp/start-github-mcp.sh
' | jq -r '
  select(.id == 2 or .id == 3) |
  if .id == 2 then
    "tools=" + ([.result.tools[].name] | sort | join(","))
  else
    "repository_read_is_error=" + ((.result.isError // false) | tostring)
  end'
```

Expected results:

- the launcher logs `readOnly=true`;
- the tool list contains repository, pull-request, and Actions read tools;
- the tool list contains no create, update, merge, dispatch, rerun, cancel, or delete tools;
- `repository_read_is_error=false`.

---

# 🔐 Authenticated API calls

Hermes exposes its authenticated API at `https://hermes.saqlainmushtaq.com`. The IngressRoute sends `/v1/*` and `/health` to API port `8642`; the dashboard stays on `/`. Use `API_SERVER_KEY` as a bearer token.

```bash
export HERMES_API_TOKEN="$(
  kubectl -n "$NAMESPACE" get secret hermes-agent-secrets \
    -o jsonpath='{.data.API_SERVER_KEY}' | base64 --decode
)"

curl -sS -i https://hermes.saqlainmushtaq.com/health

curl -sS \
  -H "Authorization: Bearer ${HERMES_API_TOKEN}" \
  https://hermes.saqlainmushtaq.com/v1/models

curl -sS \
  -H "Authorization: Bearer ${HERMES_API_TOKEN}" \
  -H "Content-Type: application/json" \
  https://hermes.saqlainmushtaq.com/v1/chat/completions \
  -d '{
    "model": "hermes-agent",
    "messages": [{"role": "user", "content": "Reply with exactly: hermes api ok"}],
    "stream": false
  }'
```

Optional local debugging path if ingress is unavailable:

```bash
kubectl -n "$NAMESPACE" port-forward svc/hermes-agent 8642:8642
curl -sS -H "Authorization: Bearer ${HERMES_API_TOKEN}" http://127.0.0.1:8642/v1/models
```

Keep `HERMES_API_TOKEN` out of logs, tickets, and shell history. Rotate `hermes-agent-secrets` if exposed.

---

# 🛡️ SRE / DevOps guardrails

The live deployment uses least-privilege, **read-only** Kubernetes RBAC for the Hermes service account so the agent can inspect cluster health without any write access.

- Cluster-wide read-only: nodes, pods/logs/events, workloads, networking, Traefik ingress routes, storage, metrics, RBAC objects, admission webhooks, PDBs.
- Namespace-local read-only extra: configmaps inside `devops-agent` (denied cluster-wide).
- Explicitly denied: secrets, cluster-wide configmaps, and **every write verb everywhere**.

See [`hermes-service-account/README.md`](hermes-service-account/README.md) for exact permissions and verification commands.

GitHub diagnostics use the official GitHub MCP server binary (resolved to the latest release at startup). No GitHub CLI or
general GitHub API tool is exposed to the agent. Access is granted by an organization-owned
GitHub App with read-only permissions across current and future repositories; each MCP
process receives a fresh one-hour installation token. The MCP server runs in read-only
mode and the Claude bridge allows only `github-sre-readonly` tools. Repository content, PR text, commit
messages, and Actions logs are untrusted evidence: the agent must never treat instructions
inside them as authority to reveal credentials, change policy, contact external systems,
or perform operational writes.

---

# 🔁 Day-2 operations

```bash
NS=devops-agent; POD=hermes-agent-0

# tail logs (gateway / bridge)
kubectl logs -n $NS $POD -c hermes -f
kubectl logs -n $NS $POD -c claude-bridge -f

# restart cleanly (picks up secret/env changes)
kubectl rollout restart statefulset/hermes-agent -n $NS

# shell in
kubectl exec -n $NS $POD -c hermes -it -- bash

# resource pressure / capacity check
kubectl top pod -n $NS
kubectl describe node | grep -A3 "Allocated resources"
```

## 🔄 Rotate dashboard password

```bash
export NEW_PASSWORD="$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits + "-_+=") for _ in range(56)))')"

export NEW_HASH="$(docker run --rm \
  --entrypoint /opt/hermes/.venv/bin/python \
  -e PYTHONPATH=/opt/hermes \
  -e HERMES_DASHBOARD_PASSWORD="$NEW_PASSWORD" \
  "$HERMES_IMAGE" \
  -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))')"

kubectl -n "$NAMESPACE" get secret hermes-agent-secrets -o yaml | \
  sed "s|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:.*|HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH: $(echo -n "$NEW_HASH" | base64 -w0)|" | \
  kubectl apply -f -

kubectl -n "$NAMESPACE" rollout restart statefulset/hermes-agent
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=300s

printf 'Dashboard password rotated. Update the approved production secret store with NEW_PASSWORD.\n'
```

## 🔍 Verify secret metadata (no values printed)

```bash
kubectl -n "$NAMESPACE" get secret hermes-agent-secrets -o json | \
  python3 -c 'import json,sys; data=json.load(sys.stdin).get("data",{}); required={"API_SERVER_KEY","HERMES_DASHBOARD_BASIC_AUTH_USERNAME","HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH","HERMES_DASHBOARD_BASIC_AUTH_SECRET","CLAUDE_CODE_PROXY_API_KEY"}; missing=sorted(required-set(data)); print("missing=" + ",".join(missing) if missing else "all required keys present")'

kubectl -n "$NAMESPACE" get secret hermes-agent-github-app -o json | \
  python3 -c 'import json,sys; data=json.load(sys.stdin).get("data",{}); required={"app-id","installation-id","private-key.pem"}; missing=sorted(required-set(data)); print("missing=" + ",".join(missing) if missing else "all GitHub App keys present")'
```

## 🔄 Rotate the GitHub App private key

Installation access tokens rotate automatically for every MCP process. Only the App private
key requires planned rotation. Generate a replacement key in the GitHub App settings, store
it in the approved secret manager, then update the Secret:

```bash
export GITHUB_APP_PRIVATE_KEY_FILE='/secure/path/to/replacement.pem'

kubectl -n "$NAMESPACE" create secret generic hermes-agent-github-app \
  --from-literal=app-id="$GITHUB_APP_ID" \
  --from-literal=installation-id="$GITHUB_APP_INSTALLATION_ID" \
  --from-file=private-key.pem="$GITHUB_APP_PRIVATE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" rollout restart statefulset/hermes-agent
kubectl -n "$NAMESPACE" rollout status statefulset/hermes-agent --timeout=300s
```

Verify MCP connectivity, then delete the previous private key from the GitHub App. Never
print or place either PEM in logs, tickets, or Git.

## 🧠 Optional dashboard skills

Keep optional skills under `kubernetes/skills/`. They must preserve the read-only posture (inspect and summarize only — no create/update/delete/comment/transition/send) unless a separate approved write path exists.

Production skills are declarative:

- Source lives in Git under `kubernetes/skills/<skill-name>/SKILL.md`.
- `kustomize` packages approved skills into the `hermes-agent-declarative-skills` ConfigMap.
- `init-hermes-config` syncs them into the PVC-backed live path `/opt/data/skills/<skill-name>/SKILL.md`.
- The Claude Code bridge can update only that approved skills directory with scoped `Write(//opt/data/skills/**)`.

Apply skill changes declaratively:

```bash
export KUBECONFIG="$HOME/.kube/config"
cd $HOME/hermes-claude-code-bridge/kubernetes

kubectl apply -k .
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=420s
```

Verify the live skill:

```bash
kubectl -n devops-agent exec statefulset/hermes-agent -c claude-bridge -- \
  sh -lc 'find "$HERMES_SKILLS_DIR" -maxdepth 2 -name SKILL.md -print | sort'
```

If the dashboard needs a manual reload after a skill-only change:

```text
/reload-skills
/skill <skill-name>
```

> ✅ Skill updates are declarative. Change Git, `kubectl apply -k .`, roll the StatefulSet, and verify the PVC path. Avoid one-off `kubectl exec` patches as the source of truth.

---

# 🩺 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod `Pending`, `Insufficient cpu` | Cluster capacity/request mismatch | Right-size requests or schedule on the approved production node pool |
| Dashboard `/health` 200 but `/` 302 forever | Normal — `/` redirects to login | Use the dashboard creds |
| Hermes "permission denied" calling a tool | Tool not in bridge `--allowed-tools` (or in `--disallowed-tools`) | Adjust the bridge args, restart |
| Browser shows `missing required Authorization header` for the old remote GitHub MCP URL | The endpoint was opened as an ordinary web page | Expected; this deployment uses its local stdio MCP launcher instead |
| `github-sre-readonly` is disconnected | Missing App secret, wrong App/installation ID, invalid PEM, or MCP binary install failure | Check Secret key presence and bridge logs without printing credentials; correct the Secret and restart |
| GitHub returns `403` | The App is not installed on the organization or a required permission is missing | Confirm the installation uses All repositories and compare the App permissions with Step 4 |
| `kubectl` context not found | Missing production cluster credentials | Re-run Step 1 |
| Dashboard login "Invalid username or password" despite correct password | Password hash made with wrong algorithm (not scrypt) | Regenerate via the Hermes image (Step 3) |
| `/opt/data` permission errors | Runtime user is UID/GID `10000:10000` | Init containers chown `/opt/data` and `/workspace/devops-agent` to `10000:10000` |

---

# 🐳 Alternative: local single-host (Docker Compose)

For laptop/single-VM testing only — not the production path. Save as `docker-compose.yml`:

```yaml
services:
  claude-bridge:
    image: node:22-bookworm-slim
    command:
      - /bin/sh
      - -lc
      - |
        set -eu
        apt-get update && apt-get install -y --no-install-recommends python3 curl ca-certificates
        npm install -g @anthropic-ai/claude-code@latest
        exec python3 /app/claude_code_bridge.py \
          --host 0.0.0.0 --port 18181 \
          --claude-bin /usr/local/bin/claude \
          --cwd /workspace --model claude-opus-4-8 --effort medium \
          --permission-mode dontAsk --max-budget-usd 3.00 \
          --allowed-tools mcp__github-sre-readonly__search_repositories,mcp__github-sre-readonly__get_file_contents,mcp__github-sre-readonly__list_commits,mcp__github-sre-readonly__list_pull_requests,mcp__github-sre-readonly__get_pull_request \
          --disallowed-tools Bash,Edit,Write,NotebookEdit \
          --api-key "$CLAUDE_CODE_PROXY_API_KEY"
    environment:
      HOME: /home/claude
      CLAUDE_CODE_PROXY_API_KEY: ${CLAUDE_CODE_PROXY_API_KEY}
    volumes:
      - ./bridge/claude_code_bridge.py:/app/claude_code_bridge.py:ro
      - hermes-state:/workspace

  hermes:
    image: nousresearch/hermes-agent:v2026.7.20
    command: ["gateway", "run"]
    depends_on: [claude-bridge]
    ports:
      - "9119:9119"   # dashboard
      - "8642:8642"   # api
    environment:
      HERMES_HOME: /opt/data
      API_SERVER_ENABLED: "true"
      HERMES_DASHBOARD: "1"
      HERMES_DASHBOARD_HOST: 0.0.0.0
      HERMES_INFERENCE_PROVIDER: claude-code-bridge
      GATEWAY_ALLOW_ALL_USERS: "true"
    volumes:
      - hermes-data:/opt/data

volumes:
  hermes-state:
  hermes-data:
```

```bash
# put secrets in a .env file (gitignored), then:
docker compose up -d
docker compose logs -f hermes        # watch startup
open http://localhost:9119           # dashboard
docker compose down                  # stop (volumes persist)
```

---

🎯 **Golden rules:** pin images · keep secrets out of git · `rollout restart` after env/secret changes · check `kubectl top` before blaming the app · read the logs of **both** containers.
