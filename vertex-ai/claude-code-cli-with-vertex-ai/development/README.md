# 🛠️ Development provider

Claude Code runs the reasoning loop on Vertex AI. Hermes executes tools and
maintains conversation history, memory, skills and command approvals.

## 🧩 Components

| File or directory | Purpose |
| --- | --- |
| `src/native_provider.py` | HTTP provider that invokes the native CLI and forwards tool requests |
| `src/hermes_executor.py` | MCP executor using the Hermes tool registry and approval handling |
| `src/claude_env.py` | Isolated child environment and Vertex model/project configuration |
| `src/claude_code_bridge.py` | CLI process management, usage parsing and HTTP support |
| `src/drain_native.py` | Requests provider drain during shutdown |
| `deploy/` | Kubernetes manifests to adapt for your environment |
| `deploy/prom-mcp/prom_readonly_mcp.py` | Read-only Prometheus/Alertmanager stdio MCP (GET only, bounded output) |

## 🔐 Command approvals

Every tool call from Claude Code goes through Hermes' own dispatch, so the
configured `approvals.deny` globs, pre-tool hooks and dangerous-command guards
apply unchanged. A flagged-but-not-denied command is never run by the executor.
Two approval modes are available; both containers must agree:

| `NATIVE_APPROVAL_RELAY` (claude-code) | `EXECUTOR_APPROVAL_UX` (hermes-executor) | Behaviour |
| --- | --- | --- |
| `1` (default in the example) | `relay` | The provider returns the parked command to Hermes as a real `terminal` tool call. Hermes' gateway shows its own Allow / Deny prompt (native buttons on platforms that support them), runs the command after approval and feeds the result back to the next model turn. |
| `0` | `typed` | The model relays a one-time id; the user replies `approve <id>` or `deny <id>` in the same conversation. Replies are matched after any gateway timestamp prefix. |

Approvals are bound to a conversation fingerprint, single-use and expire after
`EXECUTOR_APPROVAL_TTL_SECONDS` (900 by default). A relayed command is marked
`superseded` in the executor so a typed reply cannot run it a second time.
`command_allowlist` is reset on every start so persisted per-command allows on
the volume never bypass the prompt after a restart.

## 🔁 Concurrency and cancellation

The provider runs a bounded pool of `NATIVE_CONCURRENCY` native tasks (3 in the
example) with at most one task per conversation, so a long investigation in one
conversation no longer blocks the others. When the requesting client disconnects
(interrupted turn, gateway restart) the running CLI is terminated and its slot
released instead of running to `NATIVE_TASK_TIMEOUT_SECONDS`. `GET /health` on the
provider reports `running` and `concurrency`.

## 🧠 Self-improvement defaults

The example enables Hermes' own improvement loop on the auxiliary model (Sonnet
via the Vertex bridge, never the primary loop):

- `auxiliary.background_review.enabled: true` forks a review pass after enough
  turns to turn repeated procedures into skills and refresh stale ones.
- `curator.enabled: true` with `consolidate: false` and `prune_builtins: false`,
  so memory is curated but nothing an operator wrote is merged or removed.
- `memory.memory_char_limit: 6000` and `memory.user_char_limit: 3000`.

Memories live in `HERMES_HOME/memories`; the executor resolves that directory
through Hermes itself rather than a hard-coded path.

## ⚙️ Runtime configuration

The default reasoning model is **Opus 5**: `ANTHROPIC_MODEL=claude-opus-5`
and `NATIVE_CLI_MODEL=claude-opus-5[1m]`.

- Set `ANTHROPIC_VERTEX_PROJECT_ID` and `GCP_PROJECT_ALLOWED` to the same intended
  project. The example default `your-gcp-project-id` must be replaced.
- Configure `ANTHROPIC_MODEL`, `NATIVE_CLI_MODEL` and `CLOUD_ML_REGION` for a model
  and region available to your project. The checked-in defaults are examples.
- Supply `VERTEX_CLAUDE_BRIDGE_API_KEY` through a runtime Secret. Configure
  metadata-based Application Default Credentials for the CLI child process;
  `claude_env.py` intentionally excludes inherited credential-file paths.
- Optional adapters require their own runtime credentials and configuration.
- The Prometheus MCP defaults to the kube-prometheus-stack service names in the
  `monitoring` namespace; set `PROMETHEUS_URL` and `ALERTMANAGER_URL` in the
  `prometheus-readonly` entry to your own endpoints, or remove the entry.
- Replace `hermes.example.com` in the ingress example and configure your own
  routing, TLS and dashboard authentication.

| Variable | Container | Example | Purpose |
| --- | --- | --- | --- |
| `NATIVE_CONCURRENCY` | claude-code | `3` | Concurrent native tasks (one per conversation) |
| `NATIVE_APPROVAL_RELAY` | claude-code | `1` | Return parked commands as tool calls for the gateway prompt |
| `NATIVE_TASK_TIMEOUT_SECONDS` / `NATIVE_TASK_BUDGET_USD` / `NATIVE_TASK_MAX_TURNS` | claude-code | `1500` / `8` / `40` | Per-task wall-clock, spend and turn caps |
| `EXECUTOR_APPROVAL_UX` | hermes-executor | `relay` | `relay` or `typed`; must match the provider switch |
| `EXECUTOR_CONCURRENCY` | hermes-executor | `4` | Parallel tool executions |
| `GCP_PROJECT_ALLOWED` | hermes-executor | `your-gcp-project-id` | Project restriction for cloud tool calls |

## 🚀 Build and deployment prerequisites

From the repository root, render the complete example without contacting a cluster:

```sh
kubectl kustomize . > /tmp/hermes-rendered.yaml
```

The root kustomization generates all referenced ConfigMaps from checked-in source,
identity and skills. Build from that root, not directly from `development/deploy`.
Generated content hashes trigger pod replacement when those files change.

Before deployment, configure project/model values and the ingress hostname, and
provision these Secrets in the `devops-agent` namespace using your secret manager:

| Secret | Required configuration |
| --- | --- |
| `hermes-agent-secrets` | Bridge API key (at least 24 characters), dashboard authentication and enabled integration credentials |
| `hermes-agent-google-oauth` | `GOOGLE_MCP_OAUTH_CLIENT_ID`, `GOOGLE_MCP_OAUTH_CLIENT_SECRET`, `GOOGLE_MCP_OAUTH_REFRESH_TOKEN` |
| `hermes-agent-postgres-readonly` | `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE` |

The cluster needs a default StorageClass for the 20Gi persistent claim, Traefik
IngressRoute support and a configured TLS entry point. Configure Vertex ADC and IAM
for the pod's identity. The manifests create a Kubernetes service account but do not
provision cloud IAM, OAuth grants, database access, DNS or certificates. The runtime
needs outbound access for CLI installation, model calls and enabled integrations.
Pin the CLI/browser versions for reproducible installations; their current startup
configuration follows upstream releases.

Review the actual RBAC rules before granting them: despite the historical
`readonly` filenames, these examples include diagnostic pod creation/deletion,
exec/attach and ephemeral-container mutation. The development executor exposes
the tools enabled by Hermes configuration, which can include external writes.
Choose permissions and approval policies for your intended environment.

After deployment, verify pod readiness, authenticated bridge requests, executor
integration discovery and persistence in an isolated test conversation. Useful
namespace-scoped checks: `GET /health` on the provider (`running`, `concurrency`),
a harmless flagged command such as `rm -rf /tmp/probe` to see the Allow / Deny
prompt, and a denied verb such as `kubectl delete pvc <name> -n <ns>` to confirm it
is refused without a prompt. For rollback, reapply the previous reviewed
configuration and image versions; preserve the PVC. Note that `config.yaml` on the
volume is merged, not replaced, on start: a retired key must be popped explicitly
in the init step or it survives a rollback. Do not treat a successful local render
as evidence of a successful deployment.

Persistent volumes contain runtime state. Do not commit their contents, local
`.env` files, OAuth credentials, private keys, database passwords or request dumps.
No deployment status, internal operational history or benchmark results are
asserted by these examples.

## ✅ Validation

From the parent directory, run the offline unit tests:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

These tests cover the pilot helpers in the parent `src/` directory; they do not
prove that this development deployment works. Validate any adapted manifests and
run integration checks separately in your own test environment.
