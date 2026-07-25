# 🔑 secrets/

`secret.template.yaml` is a **template**. Never `kubectl apply -f` it directly and never commit real values — it is intentionally excluded from `kustomization.yaml` so `kubectl apply -k .` cannot pull placeholders into the cluster.

```bash
export API_SERVER_KEY="$(openssl rand -hex 32)"
export OPENCODE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='<bcrypt hash>'

envsubst < secret.template.yaml | kubectl apply -f -
```

Generate the dashboard hash with the **same Hermes image** the StatefulSet runs, so the bcrypt implementation matches:

```bash
docker run --rm -it nousresearch/hermes-agent:v2026.7.20 \
  /opt/hermes/.venv/bin/python -c \
  'import bcrypt,getpass; print(bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt()).decode())'
```

## What each value is for

| Key | Required | Purpose |
|-----|----------|---------|
| `API_SERVER_KEY` | ✅ | Bearer token for Hermes' API server (`:8642`) |
| `HERMES_DASHBOARD_BASIC_AUTH_*` | ✅ | Dashboard login + session signing |
| `OPENCODE_BRIDGE_API_KEY` | ✅ | Shared secret between Hermes and the bridge. The bridge listens on loopback only, but requiring a bearer means another container in the pod can't drive the OpenCode CLI anonymously |
| `OPENCODE_API_KEY` | ❌ | **Not needed.** opencode zen's free models work unauthenticated. Seed it only to reach paid models, and then also set `OPENCODE_BRIDGE_FREE_ONLY: "false"` |
| `HERMES_VISION_*` | ❌ | Route Hermes' auxiliary Vision task to an image-capable endpoint — the free models are text-only |
| `HERMES_DEFAULT_*` | ❌ | First-run model seed; dashboard changes are preserved after that |
| `HERMES_EXTRA_PROVIDERS_YAML` | ❌ | Add Hermes providers without editing manifests. Removing an entry also removes it from `config.yaml` on the next restart |

## Rotation

```bash
export OPENCODE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
envsubst < secret.template.yaml | kubectl apply -f -
kubectl -n devops-agent rollout restart statefulset/hermes-agent
```

The restart is required: `init-hermes-config` writes the bridge key into `config.yaml`, and both the bridge and Hermes read their credentials at startup.

For a real cluster, prefer External Secrets / Secret Manager over `envsubst` — this template exists so the deployment is reproducible without one, not as a recommendation.
