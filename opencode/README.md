# 🆓 OpenCode Bridges

Bridges that put the **OpenCode** CLI behind an OpenAI-compatible endpoint, so Hermes can drive OpenCode's **free** models (opencode zen: MiMo, DeepSeek, Nemotron, Ling, Laguna, Big Pickle) at zero cost.

Same wire protocol as the Claude Code bridges in this repo — different backend, different port, so both can run side by side and you switch between them in Hermes' model picker.

| Folder | Target | Endpoint |
|--------|--------|----------|
| [`hermes-desktop/`](hermes-desktop) | 🖥️ Hermes desktop app on macOS / Linux (custom endpoint) | `http://127.0.0.1:18282/v1` |
| [`kubernetes/`](kubernetes) | ☸️ Production: Hermes + bridge sidecar on GKE, read-only SRE agent, Traefik dashboard | in-pod loopback `:18282` |

```bash
# laptop
cd hermes-desktop && ./install-opencode-bridge.sh

# cluster (self-contained Kustomize root)
cd kubernetes && kubectl apply -k .
```

Then in Hermes: **Settings → Providers → Custom Endpoints → `+ New endpoint`** → Endpoint URL `http://127.0.0.1:18282/v1`, Default Model `opencode/mimo-v2.5-free`, ☑️ Discover models → **⚡ Test** → **💾 Save**.

> ⚠️ Click **Test** *before* **Save** — Save persists the catalogue Test discovered. Skipping it leaves a single-entry model dropdown that looks like a stale cache but isn't.

Full docs, configuration and troubleshooting: [`hermes-desktop/README.md`](hermes-desktop/README.md) · [`kubernetes/README.md`](kubernetes/README.md).

The cluster deployment adds a four-layer read-only posture (OpenCode permission policy → read-only `kubectl` wrapper → read-only RBAC → unprivileged container) so the agent can investigate production without being able to change it — at $0 inference cost.
