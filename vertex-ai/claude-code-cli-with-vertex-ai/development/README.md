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
- Replace `hermes.example.com` in the ingress example and configure your own
  routing, TLS and dashboard authentication.

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
integration discovery and persistence in an isolated test conversation. For rollback,
reapply the previous reviewed configuration and image versions; preserve the PVC.
Do not treat a successful local render as evidence of a successful deployment.

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
