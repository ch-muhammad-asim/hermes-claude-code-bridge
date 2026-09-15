# 🧩 configmaps/

Every tunable in this deployment lives here, so day-to-day changes never touch the pod spec.

| File | ConfigMap | What it carries |
|------|-----------|-----------------|
| `configmap-opencode-bridge-env.yaml` | `hermes-agent-opencode-bridge-env` | Bridge settings: model, free-only guard, concurrency, timeouts, install paths, the sidecar image |
| `configmap-opencode-bridge-startup.yaml` | `hermes-agent-opencode-bridge-startup` | `start-opencode-bridge.sh` (installs OpenCode, optional credentials, then execs the bridge) **and** `kubectl-ro`, the read-only kubectl wrapper |
| `configmap-opencode-config.yaml` | `hermes-agent-opencode-config` | `opencode.json` — the OpenCode permission policy (layer 1 of the read-only posture) |
| `configmap-hermes-runtime-env.yaml` | `hermes-agent-runtime-env` | Images, shared paths, gateway/dashboard settings, first-run model seed |
| `configmap-hermes-runtime-scripts.yaml` | `hermes-agent-runtime-scripts` | The four init scripts + the Hermes `postStart` hook |

After editing any of these:

```bash
kubectl apply -k ..
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

A mounted ConfigMap file (`opencode.json`) does eventually refresh in-place, but the bridge and OpenCode read their config at startup — so restart rather than wait.

## Editing notes that will save you a debugging round

- **Images are declared once**, in the env ConfigMaps, and injected into the StatefulSet by Kustomize replacements. Change `HERMES_IMAGE` / `OPENCODE_BRIDGE_IMAGE` here, never in `workloads/statefulset.yaml`.
- **`kubectl-ro` is a separate ConfigMap key, not a heredoc** inside the startup script. That is deliberate: a heredoc nested in a YAML block scalar inherits the block's indentation, which pushes the `#!/bin/sh` off column 0 and stops an unindented terminator (`WRAPPER`) from ever matching. Keep new scripts as their own keys.
- **The Python in `init-hermes-config.sh` must stay flush with the surrounding shell** (both at the same YAML indentation), so the `PY` terminator lands at column 0 after YAML strips the block indent. Verify after editing:
  ```bash
  python3 -c "
  import yaml,re
  b=yaml.safe_load(open('configmap-hermes-runtime-scripts.yaml'))['data']['init-hermes-config.sh']
  code=re.search(r\"<<'PY'\n(.*?)\nPY\b\", b, re.S).group(1)
  compile(code,'x','exec'); print('embedded python OK')"
  ```
- **Syntax-check the shell** before applying — a broken script means CrashLoopBackOff, not a render error:
  ```bash
  python3 -c "
  import yaml,subprocess,pathlib
  for f in ('configmap-opencode-bridge-startup.yaml','configmap-hermes-runtime-scripts.yaml'):
      for name,body in yaml.safe_load(open(f))['data'].items():
          p=pathlib.Path('/tmp/'+name); p.write_text(body)
          sh='bash' if body.startswith('#!/bin/bash') else 'sh'
          r=subprocess.run([sh,'-n',str(p)],capture_output=True,text=True)
          print(name, 'OK' if r.returncode==0 else 'FAIL '+r.stderr)"
  ```
- **Widening the permission policy** in `configmap-opencode-config.yaml` is the one edit with security consequences. Read the verified-semantics notes in that file first — in particular that `ask` + the bridge's auto-approve flag (`--dangerously-skip-permissions`) equals `allow`, and that a `bash` pattern map with a catch-all `deny` removes the tool entirely instead of narrowing it.
