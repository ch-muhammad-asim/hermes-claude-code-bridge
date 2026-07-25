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
export API_SERVER_KEY=... HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=... # …etc
envsubst < secrets/secret.template.yaml | kubectl apply -f -
```

> 🔒 `.gitignore` blocks `secret*.yaml` (real secrets) while allowing `*.template.yaml`, so a rendered secret can never be committed by accident.
