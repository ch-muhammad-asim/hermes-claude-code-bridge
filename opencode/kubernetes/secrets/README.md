# 🔑 secrets/

`secret.template.yaml` is a **template**. Never `kubectl apply -f` it directly and never commit real values — it is intentionally excluded from `kustomization.yaml` so `kubectl apply -k .` cannot pull placeholders into the cluster.

```bash
export API_SERVER_KEY="$(openssl rand -hex 32)"
export OPENCODE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='<scrypt$... hash — see below>'

envsubst < secret.template.yaml | kubectl apply -f -
```

Generate the dashboard hash with Hermes' **own** `hash_password()` from the **same image** the
StatefulSet runs. Hermes hashes with **scrypt**; a generic `bcrypt`/`sha256` hash is accepted by
`kubectl` but then **silently rejects every login**:

```bash
export HERMES_DASHBOARD_PASSWORD='<your dashboard password>'

export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$(
  docker run --rm \
    --entrypoint /opt/hermes/.venv/bin/python \
    -e PYTHONPATH=/opt/hermes \
    -e HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
    nousresearch/hermes-agent:v2026.7.20 \
    -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))'
)"
echo "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH"   # -> scrypt$16384$8$1$...
```

> 🧷 **`--entrypoint` is mandatory.** Without it the image's s6-overlay init boots the whole
> supervisor first, printing service logs and (with `-it`) waiting on a TTY — the hash never lands
> cleanly in the variable. Passing the password via `-e` rather than `getpass` keeps it
> non-interactive so it works inside `$( )`.

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
