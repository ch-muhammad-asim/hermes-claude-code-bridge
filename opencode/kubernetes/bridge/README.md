# 🌉 bridge/

`opencode_bridge.py` — the stdlib-only OpenAI-compatible bridge that fulfils each chat-completions request by invoking `opencode run --format json`.

Kustomize turns this file into the `hermes-agent-opencode-bridge` ConfigMap and mounts it read-only at `/app/opencode_bridge.py` in the sidecar. One copy, no duplicate source tree.

It is byte-identical to [`../../hermes-desktop/opencode_bridge.py`](../../hermes-desktop/opencode_bridge.py) — the same script serves the desktop app and the cluster; only the flags differ (supplied by `configmaps/configmap-opencode-bridge-startup.yaml`). After changing one, copy it across and re-run the selfcheck:

```bash
cp ../../hermes-desktop/opencode_bridge.py opencode_bridge.py
BRIDGE_SELFCHECK=1 python3 opencode_bridge.py     # -> selfcheck ok
diff ../../hermes-desktop/opencode_bridge.py opencode_bridge.py && echo "in sync"
```

`selfcheck` is offline and needs no `opencode` binary: it covers prompt assembly, the OpenCode-tokens → chat-completions usage mapping, `models --verbose` parsing, model resolution (including bare-id aliases and the free-only refusal), error classification, and command construction.

Run it locally against your own OpenCode install:

```bash
python3 opencode_bridge.py --port 18282 --cwd "$PWD"
curl -s http://127.0.0.1:18282/v1/models
```

Full flag reference: `python3 opencode_bridge.py --help`.
