# 🔑 secrets/

Two templates live here: `secret.template.yaml` (OmniRoute) and `hermes-secret.template.yaml`
(Hermes, including `OMNIROUTE_CLIENT_API_KEY` — the key Hermes presents to OmniRoute).

`secret.template.yaml` is a **template**, not a manifest. It holds `${...}` placeholders and is
deliberately **excluded from `kustomization.yaml`**, so `kubectl apply -k .` can never push placeholder
strings into the cluster.

## Render and apply

```bash
export JWT_SECRET="$(openssl rand -base64 48)"
export API_KEY_SECRET="$(openssl rand -hex 32)"
export INITIAL_PASSWORD='<strong password — store it in a password manager>'

envsubst < secret.template.yaml | kubectl -n omniroute apply -f -
```

`envsubst` ships with GNU gettext (`brew install gettext` on macOS). Verify only the key **names**, never
the values:

```bash
kubectl -n omniroute get secret omniroute-secrets -o json | jq -r '.data | keys[]' | sort
```

> 🔒 The repo's `.gitignore` blocks `secret.yaml` and `secret-*.yaml` while allowing `*.template.yaml`, so
> a rendered secret cannot be committed by accident. Never paste real values into this file.

## What each key is for

| Key | Required | Generate | Purpose |
|-----|----------|----------|---------|
| `JWT_SECRET` | ✅ | `openssl rand -base64 48` | Signs dashboard session cookies |
| `API_KEY_SECRET` | ✅ | `openssl rand -hex 32` | Encrypts provider API keys at rest in SQLite |
| `INITIAL_PASSWORD` | ✅ | your own | First-boot dashboard password. Hashed to bcrypt on startup; change it afterwards in **Settings → Security**. It seeds **only** the first boot against an empty database. |
| `STORAGE_ENCRYPTION_KEY` | ❌ | `openssl rand -hex 32` | Encrypts the whole SQLite database at rest. ⚠️ **Back it up** — without it an existing database cannot be opened again. |
| `OMNIROUTE_WS_BRIDGE_SECRET` | ❌ | `openssl rand -hex 32` | Shared secret for the WebSocket bridge; set it for any non-local deployment. |
| `REDIS_URL` | ❌ | — | Shared rate-limit state. Unset ⇒ in-memory rate limiting, which is correct for a single replica. |

Provider API keys are **not** here — they are added in the dashboard at runtime and stored encrypted in
OmniRoute's database.

## Rotation

`JWT_SECRET` and `API_KEY_SECRET` are read at startup, so patch the Secret and roll the pod:

```bash
kubectl -n omniroute patch secret omniroute-secrets --type merge \
  -p "{\"stringData\":{\"JWT_SECRET\":\"$(openssl rand -base64 48)\"}}"
kubectl -n omniroute rollout restart statefulset/omniroute
```

- Rotating **`JWT_SECRET`** invalidates active dashboard sessions — everyone logs in again.
- Rotating **`API_KEY_SECRET`** makes already-encrypted provider keys unreadable; re-enter those
  connections in the dashboard afterwards. Don't rotate it casually.
- Rotating **`STORAGE_ENCRYPTION_KEY`** on an existing database makes it unopenable. Treat it as
  write-once unless you are following an upstream key-rotation procedure.
