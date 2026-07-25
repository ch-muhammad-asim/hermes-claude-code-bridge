# 🌉 Vertex Claude Bridge Commands

This folder contains the standalone Python bridge that lets Hermes call Claude Opus 4.8 through the Vertex AI Anthropic partner-model endpoint.

Runtime path:

```text
Hermes -> vertex_claude_bridge.py -> Vertex AI Anthropic endpoint -> claude-opus-4-8
```

The bridge does not use Claude Code, `claude -p`, or a Claude subscription.

## 🔑 1. Required IAM

`roles/aiplatform.user` is the only role the bridge needs, granted to whichever identity runs it:

- **In-cluster (production):** the pod authenticates via **GKE Workload Identity** — the `hermes-agent`
  KSA is bound to the `hermes-vertex` Google service account carrying `roles/aiplatform.user`. One-time
  setup commands: [`../README.md`](../README.md) → **Workload Identity (Vertex AI)**.
- **Local development:** grant your own user the same role so local ADC works:

```bash
gcloud projects add-iam-policy-binding your-gcp-project-id \
  --member="user:you@your-domain.com" \
  --role="roles/aiplatform.user"
```

If you are using Agent Studio / Agent Platform features separately, `Vertex AI Agent Platform User` may also be useful, but this bridge primarily needs `roles/aiplatform.user`.

## 🔌 2. Enable / Confirm APIs

```bash
gcloud services enable aiplatform.googleapis.com \
  --project your-gcp-project-id

gcloud services list \
  --enabled \
  --project your-gcp-project-id \
  --filter="config.name:aiplatform.googleapis.com"
```

Also confirm `claude-opus-4-8` is enabled or accepted in Vertex AI Model Garden for `your-gcp-project-id`.

## 🛠️ 3. Local Setup

```bash
cd vertex-ai/kubernetes/bridge

python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

## 🔐 4. Local Google Auth

```bash
gcloud auth application-default login
gcloud config set project your-gcp-project-id
gcloud auth application-default set-quota-project your-gcp-project-id
```

Verify ADC can be resolved:

```bash
python3 - <<'PY'
import google.auth
creds, project = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
print(project)
print(type(creds).__name__)
PY
```

## ▶️ 5. Run Locally

```bash
export ANTHROPIC_VERTEX_PROJECT_ID="your-gcp-project-id"
export CLOUD_ML_REGION="global"
export ANTHROPIC_MODEL="claude-opus-4-8"
export VERTEX_CLAUDE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export VERTEX_CLAUDE_MAX_TOKENS="8192"
export VERTEX_CLAUDE_TIMEOUT_SECONDS="300"
export VERTEX_CLAUDE_PROMPT_CACHING="1"
export VERTEX_CLAUDE_MAX_RETRIES="2"

python3 vertex_claude_bridge.py \
  --host 0.0.0.0 \
  --port 18182
```

## 🧪 6. Local Validation

Health:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" \
  http://127.0.0.1:18182/health
```

Models:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" \
  http://127.0.0.1:18182/v1/models
```

Chat completion:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:18182/v1/chat/completions \
  -d '{
    "model": "claude-opus-4-8",
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: vertex claude ok"
      }
    ],
    "stream": false,
    "max_tokens": 128
  }'
```

Streaming validation:

```bash
curl -N -sS \
  -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:18182/v1/chat/completions \
  -d '{
    "model": "claude-opus-4-8",
    "messages": [
      {
        "role": "user",
        "content": "Reply with one short sentence."
      }
    ],
    "stream": true,
    "max_tokens": 128
  }'
```

## 🤫 7. Kubernetes Secret

Do not print secret values. Create or update the dedicated Vertex bridge key:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod
export NAMESPACE=devops-agent
export VERTEX_CLAUDE_BRIDGE_API_KEY="$(openssl rand -hex 32)"

kubectl -n "$NAMESPACE" create secret generic hermes-agent-secrets \
  --from-literal=VERTEX_CLAUDE_BRIDGE_API_KEY="$VERTEX_CLAUDE_BRIDGE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

If `hermes-agent-secrets` already exists and you only need to add the Vertex key without changing other keys:

```bash
kubectl -n "$NAMESPACE" patch secret hermes-agent-secrets \
  --type='json' \
  -p="[{\"op\":\"add\",\"path\":\"/data/VERTEX_CLAUDE_BRIDGE_API_KEY\",\"value\":\"$(printf %s "$VERTEX_CLAUDE_BRIDGE_API_KEY" | base64 | tr -d '\n')\"}]"
```

Verify key names only:

```bash
kubectl -n "$NAMESPACE" get secret hermes-agent-secrets -o json | jq -r '.data | keys[]' | sort
```

## 🚀 8. Apply Kubernetes Manifests

The manifest set is self-contained — a plain Kustomize apply from the deploy root:

```bash
cd vertex-ai/kubernetes

kubectl apply -k .

kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=10m
```

## ✅ 9. Kubernetes Validation

Pod and containers:

```bash
kubectl -n devops-agent get pod hermes-agent-0 -o wide
kubectl -n devops-agent get pod hermes-agent-0 \
  -o jsonpath='{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}={.ready}{"\n"}{end}'
```

Confirm the pod references the dedicated Vertex key:

```bash
kubectl -n devops-agent get pod hermes-agent-0 \
  -o jsonpath='{range .spec.containers[*]}{.name}:{range .env[*]}{.name}={.valueFrom.secretKeyRef.key}{","}{end}{"\n"}{end}'
```

Bridge logs:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c vertex-claude-bridge --tail=50
```

In-cluster health:

```bash
kubectl -n devops-agent run vertex-bridge-curl \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_CLAUDE_BRIDGE_API_KEY=$VERTEX_CLAUDE_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS -H "Authorization: Bearer $VERTEX_CLAUDE_BRIDGE_API_KEY" http://hermes-agent:18182/health'
```

Public dashboard health:

```bash
curl -sS https://devops.saqlainmushtaq.com/health
```

## 💬 10. Slack Home Channel Cleanup

The production home channel is `#devops` (`C0123456789`). Verify the runtime and PVC are aligned:

```bash
kubectl -n devops-agent exec -i statefulset/hermes-agent -c hermes -- \
  /opt/hermes/.venv/bin/python - <<'PY'
from pathlib import Path
import os, yaml

config = yaml.safe_load(Path("/opt/data/config.yaml").read_text()) or {}
home = (config.get("platforms", {}).get("slack", {}).get("home_channel") or {})
env_lines = [
    line for line in Path("/opt/data/.env").read_text().splitlines()
    if line.startswith("SLACK_HOME_CHANNEL")
]
print("process_SLACK_HOME_CHANNEL=" + str(os.environ.get("SLACK_HOME_CHANNEL")))
print("config_home_chat_id=" + str(home.get("chat_id")))
print("config_home_name=" + str(home.get("name")))
print("pvc_env=" + "|".join(env_lines))
PY
```

Expected:

```text
process_SLACK_HOME_CHANNEL=C0123456789
config_home_chat_id=C0123456789
config_home_name=devops
```

## 🛟 11. Troubleshooting

If the bridge starts but Vertex calls fail:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c vertex-claude-bridge --tail=100
```

Common causes:

- `roles/aiplatform.user` missing for the calling identity.
- `aiplatform.googleapis.com` disabled.
- Claude Opus 4.8 not accepted/enabled in Model Garden.
- ADC unavailable in the runtime environment.
- `VERTEX_CLAUDE_BRIDGE_API_KEY` missing from `hermes-agent-secrets`.

If Slack says no home channel is set, verify Section 10 and restart:

```bash
kubectl -n devops-agent rollout restart statefulset/hermes-agent
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=10m
```
