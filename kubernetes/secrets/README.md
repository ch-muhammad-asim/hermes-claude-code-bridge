# 🔑 Secret Templates

Envsubst **templates** for the Secrets the deployment consumes. They contain **only `${VAR}` placeholders** — never real values — and are intentionally **not** part of `../kustomization.yaml` (secrets are created out-of-band so plaintext never lands in Git).

| File | Secret | Holds |
|------|--------|-------|
| `secret.template.yaml` | `hermes-agent-secrets` | Dashboard basic-auth hash, API server key, bridge proxy key |
| `secret-github-app.template.yaml` | `hermes-agent-github-app` | GitHub App private key (`.pem`) for the read-only GitHub MCP |
| `secret-google-oauth.template.yaml` | `hermes-agent-google-oauth` | Offline OAuth refresh token for the read-only GCP MCP bridge |

## 🚫 Do not apply these directly

`kubectl apply -f secret.template.yaml` would store the literal `${...}` strings. Instead, either render with `envsubst` after exporting the variables, or use `kubectl create secret --from-literal` (see the deployment steps in [`../README.md`](../README.md)):

```bash
cd kubernetes                                    # paths below are relative to the deploy root
export API_SERVER_KEY=... HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=... # …etc
envsubst < secrets/secret.template.yaml | kubectl apply -f -
```

> ⚠️ Generate `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` with Hermes' own `hash_password()` from the
> matching image — see [`../README.md`](../README.md) → *Step 3*. Hermes uses **scrypt**; a generic
> `bcrypt`/`sha256` hash applies cleanly but then silently rejects every dashboard login.

> 🔒 `.gitignore` blocks `secret*.yaml` (real secrets) while allowing `*.template.yaml`, so a rendered secret can never be committed by accident.
