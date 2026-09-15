# ⚙️ ConfigMaps

Non-secret configuration for the Hermes Agent StatefulSet. All are referenced by [`../kustomization.yaml`](../kustomization.yaml) and mounted/consumed by the pod.

| File | Purpose |
|------|---------|
| `configmap-hermes-runtime-env.yaml` | 🧠 Hermes gateway/runtime env — images, ports, paths, GCP project (via `hermes-params`) |
| `configmap-hermes-runtime-scripts.yaml` | 🩹 Init/runtime shell scripts — installs Claude Code + kubectl, syncs skills, writes Hermes config |
| `configmap-claude-bridge-env.yaml` | 🌉 Claude Code bridge sidecar env — model, effort, budget, and the read-only tool allow/deny policy |
| `configmap-claude-bridge-startup.yaml` | 🚀 Bridge startup script — installs Claude Code + `github-mcp-server` (latest, checksum-verified) |
| `configmap-claude-permissions.yaml` | 🔐 Claude Code `settings.local.json` — the read-only allow/deny tool lists (kept in sync with the bridge env) |
| `configmap-claude-mcp.yaml` | 🔌 Declarative MCP server config (GitHub read-only stdio launcher) |

> 🧩 The bridge implementation itself (`claude_code_bridge.py`, `gcp_mcp_auth_bridge.py`) is packaged into a ConfigMap by the `configMapGenerator` in `../kustomization.yaml` — the sources live in [`../bridge`](../bridge).
