# 🌉 Vertex Gemini Bridge Commands

This folder contains the production bridge used by the Vertex AI deployment. The configured runtime path is **Gemini 3.5 Flash only**:

```text
Hermes
  -> vertex_gemini_bridge.py
  -> Vertex AI OpenAI-compatible chat-completions endpoint
  -> gemini-3.5-flash
```

The bridge does not use Claude Code, `claude -p`, or a Claude subscription. It also does not translate tool schemas: Vertex AI already exposes an OpenAI-compatible chat-completions surface for Gemini, so the bridge is intentionally thin.

> `vertex_claude_bridge.py` is retained in Git as a legacy/alternate implementation for the Anthropic partner-model path. It is **not** packaged into the production ConfigMap, is not selected by the StatefulSet, and is not a configured fallback model.

## What the Gemini bridge does

`vertex_gemini_bridge.py`:

- exposes `GET /health`, `GET /v1/models`, and `POST /v1/chat/completions`;
- authenticates to Google with ADC / GKE Workload Identity;
- authenticates Hermes to the local bridge with `VERTEX_GEMINI_BRIDGE_API_KEY`;
- qualifies the configured model as `google/gemini-3.5-flash` for Vertex and normalizes the response model back to `gemini-3.5-flash` for Hermes;
- forwards tool definitions, tool calls, tool results, and SSE streaming without schema translation;
- retries transient `429/500/502/503/504` and connection failures with bounded exponential backoff;
- logs prompt, output, reasoning, and total token usage;
- rejects oversized prompts using `VERTEX_GEMINI_MAX_PROMPT_CHARS`.

## 🔑 1. Required IAM

`roles/aiplatform.user` is the only Vertex role the bridge needs, granted to whichever identity runs it:

- **In-cluster (production):** the pod authenticates via **GKE Workload Identity**. The `hermes-agent` KSA is bound to the production GSA; see [`../README.md`](../README.md) → **Workload Identity (Vertex AI)**.
- **Local development:** grant your own Google identity the same role so Application Default Credentials can invoke Vertex AI.

Example local grant:

```bash
export PROJECT_ID="your-gcp-project-id"
export USER_EMAIL="you@your-domain.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${USER_EMAIL}" \
  --role="roles/aiplatform.user"
```

## 🔌 2. Enable the Vertex AI API

```bash
export PROJECT_ID="your-gcp-project-id"

gcloud services enable aiplatform.googleapis.com --project "$PROJECT_ID"
gcloud services list \
  --enabled \
  --project "$PROJECT_ID" \
  --filter="config.name:aiplatform.googleapis.com"
```

The production model is `gemini-3.5-flash` and the configured Vertex location is `global`.

## 🛠️ 3. Local setup

```bash
cd vertex-ai/kubernetes/bridge

python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

## 🔐 4. Local Google authentication

```bash
gcloud auth application-default login
gcloud config set project "$PROJECT_ID"
gcloud auth application-default set-quota-project "$PROJECT_ID"
```

Verify ADC:

```bash
python3 - <<'PY'
import google.auth
creds, project = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
print("project:", project)
print("credentials:", type(creds).__name__)
PY
```

## ▶️ 5. Run the Gemini bridge locally

```bash
export VERTEX_GEMINI_PROJECT_ID="$PROJECT_ID"
export CLOUD_ML_REGION="global"
export GEMINI_MODEL="gemini-3.5-flash"
export VERTEX_GEMINI_BRIDGE_API_KEY="$(openssl rand -hex 32)"
export VERTEX_GEMINI_MAX_TOKENS="8192"
export VERTEX_GEMINI_TIMEOUT_SECONDS="300"
export VERTEX_GEMINI_MAX_RETRIES="2"
export VERTEX_GEMINI_MAX_PROMPT_CHARS="200000"

python3 vertex_gemini_bridge.py \
  --host 0.0.0.0 \
  --port 18182
```

In GKE, `VERTEX_GEMINI_PROJECT_ID` is intentionally omitted so `google.auth.default()` resolves the project from Workload Identity. Set it only when you deliberately need a different billing/project target.

## 🧪 6. Local validation

Health:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" \
  http://127.0.0.1:18182/health
```

Expected model metadata includes:

```text
provider: vertex-gemini
location: global
model: gemini-3.5-flash
```

Models:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" \
  http://127.0.0.1:18182/v1/models
```

Chat completion:

```bash
curl -sS \
  -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:18182/v1/chat/completions \
  -d '{
    "model": "gemini-3.5-flash",
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: vertex gemini ok"
      }
    ],
    "stream": false,
    "max_tokens": 128
  }'
```

Streaming validation:

```bash
curl -N -sS \
  -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:18182/v1/chat/completions \
  -d '{
    "model": "gemini-3.5-flash",
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

## 🤫 7. Kubernetes secret

Create or rotate the bridge key without printing it:

```bash
export KUBECONFIG=$HOME/.kube/clusters/prod
export NAMESPACE=devops-agent
export VERTEX_GEMINI_BRIDGE_API_KEY="$(openssl rand -hex 32)"

kubectl -n "$NAMESPACE" create secret generic hermes-agent-secrets \
  --from-literal=VERTEX_GEMINI_BRIDGE_API_KEY="$VERTEX_GEMINI_BRIDGE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

If `hermes-agent-secrets` also contains dashboard/API values, use the full secret creation flow in [`../README.md`](../README.md) rather than replacing unrelated keys accidentally.

## 🚀 8. Deploy

```bash
cd vertex-ai/kubernetes
kubectl apply -k .
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=10m
```

The production Kustomization packages `vertex_gemini_bridge.py` and `requirements.txt`. The legacy Claude bridge is not part of the runtime ConfigMap.

## ✅ 9. In-cluster validation

Pod health:

```bash
kubectl -n devops-agent get pod hermes-agent-0 -o wide
kubectl -n devops-agent get pod hermes-agent-0 \
  -o jsonpath='{.status.phase}{"\n"}{range .status.containerStatuses[*]}{.name}={.ready}{"\n"}{end}'
```

Bridge logs:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c vertex-gemini-bridge --tail=50
```

Confirm the resolved runtime model:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c vertex-gemini-bridge \
  | grep 'listening on' | tail -1
```

Expected:

```text
location=global model=gemini-3.5-flash auth=on
```

In-cluster health:

```bash
kubectl -n devops-agent run vertex-bridge-curl \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.16.0 \
  --env="VERTEX_GEMINI_BRIDGE_API_KEY=$VERTEX_GEMINI_BRIDGE_API_KEY" \
  -- sh -lc 'curl -sS -H "Authorization: Bearer $VERTEX_GEMINI_BRIDGE_API_KEY" http://hermes-agent:18182/health'
```

## 🛟 10. Troubleshooting

### `401 unauthorized`

The client and bridge do not share the same `VERTEX_GEMINI_BRIDGE_API_KEY`. Rotate the Kubernetes Secret, then roll the StatefulSet.

### `auth=off` in bridge startup logs

Treat this as a deployment failure. The bridge accepts requests without authentication when the configured key is empty. Verify the Secret key exists and is non-empty, then restart the pod.

### `404 model not found`

Confirm:

```text
CLOUD_ML_REGION=global
GEMINI_MODEL=gemini-3.5-flash
```

The deployment intentionally uses the global Vertex endpoint for Gemini 3.x.

### `403` from Vertex AI

Verify Workload Identity and that the effective GSA has `roles/aiplatform.user` for the target project.

### Long-running or failed model calls

Check the sidecar logs for retryable `429/5xx` responses and token usage. The bridge retries only a bounded number of times; persistent provider errors are surfaced to Hermes instead of looping indefinitely.

## Legacy Claude bridge

`vertex_claude_bridge.py` remains in this directory only as an alternate implementation/reference for Vertex AI Anthropic partner models. It has its own `VERTEX_CLAUDE_*` / `ANTHROPIC_*` configuration contract and is intentionally outside the production Kustomize runtime.

Do not add a Claude provider or Claude model fallback to `config.yaml` unless the deployment architecture is deliberately changed and reviewed. The supported production configuration documented in `vertex-ai/` has one default model: **`gemini-3.5-flash`**.
