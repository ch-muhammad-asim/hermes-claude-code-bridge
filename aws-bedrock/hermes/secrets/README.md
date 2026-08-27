# 🔑 Secrets

`secret.template.yaml` is a **template**. Do not apply it as-is, and never commit real
values into it. Render it from the environment:

```bash
envsubst < secret.template.yaml | kubectl apply -f -
```

## 📦 `hermes-agent-secrets` (required)

| Key | How to produce it |
|---|---|
| `API_SERVER_KEY` | `openssl rand -hex 32` |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | scrypt, one-way — see below |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -hex 32` |
| `BEDROCK_CLAUDE_BRIDGE_API_KEY` | `openssl rand -hex 32` — the bearer token Hermes presents to the bridge |

The password hash **must be generated with the exact image the StatefulSet runs**, or it
is produced by a different build than the one verifying it. The hash is one-way: losing
the plaintext means rotating, not recovering. Full recipe in `../README.md` → step 3.

## 🐙 `hermes-agent-github-app` (optional)

| Key | Purpose |
|---|---|
| `app-id` | GitHub App ID |
| `installation-id` | Numeric installation id on your org |
| `private-key.pem` | The App's private key |

Marked `optional: true` in the StatefulSet, so the pod starts without it and `gh` is
simply unauthenticated until you create it and roll. Use **read-only** App permissions
only (Contents, Metadata, Pull requests, Actions, Checks). Never render the PEM into a
ConfigMap.

```bash
kubectl -n devops-agent create secret generic hermes-agent-github-app --from-literal=app-id="$GITHUB_APP_ID" --from-literal=installation-id="$GITHUB_APP_INSTALLATION_ID" --from-file=private-key.pem="$GITHUB_APP_PRIVATE_KEY_FILE"
```

## ☁️ There is deliberately no AWS credential here

Bedrock access comes from EKS Pod Identity (or, on k3s, the EC2 instance profile) — see
`../rbac/serviceaccount.yaml`. Credentials are keyless and short-lived, minted by the
platform. If you find yourself adding `AWS_ACCESS_KEY_ID` to this Secret, the Pod Identity
association is missing; fix that instead.
