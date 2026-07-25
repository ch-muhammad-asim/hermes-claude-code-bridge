# 🌉 Bridge & MCP Sources

Python sources for the in-cluster bridge and the read-only GCP MCP auth path. `claude_code_bridge.py` and `gcp_mcp_auth_bridge.py` are packaged into the `hermes-agent-claude-bridge` ConfigMap by the `configMapGenerator` in [`../kustomization.yaml`](../kustomization.yaml) and mounted into the `claude-bridge` sidecar at `/app`.

| File | Role |
|------|------|
| `claude_code_bridge.py` | 🌉 OpenAI-compatible bridge — turns `claude -p` into `/v1/chat/completions` (streaming, usage/cost, bounded concurrency, model pass-through). Stdlib only. |
| `gcp_mcp_auth_bridge.py` | 🔐 Loopback auth bridge — fronts the Google Cloud MCP endpoints on `127.0.0.1:19190` and injects a short-lived bearer minted from the offline refresh token, so no interactive OAuth runs in-cluster. |
| `get-gcp-mcp-refresh-token.py` | 🎟️ One-time operator helper (run on a laptop) to obtain the offline refresh token seeded into the `hermes-agent-google-oauth` Secret. |
| `test_gcp_mcp_auth_bridge.py` | 🧪 Stdlib unit test for the auth bridge's token-refresh logic. |

```bash
# run the test (stdlib only)
python3 bridge/test_gcp_mcp_auth_bridge.py
```

> ℹ️ This is the Kubernetes copy of the bridge. The cross-platform desktop/container copies live in [`../../claude-bridge-with-hermes`](../../claude-bridge-with-hermes), [`../../mac`](../../mac), [`../../windows`](../../windows), and [`../../docker`](../../docker).
