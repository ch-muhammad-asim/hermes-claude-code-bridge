# 🌉 bedrock-claude-bridge — local dev and validation

`bedrock_claude_bridge.py` is a chat-completions-compatible HTTP shim in front of
Amazon Bedrock's Anthropic Messages API. Hermes speaks chat-completions; Bedrock
speaks Anthropic Messages over `InvokeModel`. This translates between them and
preserves the full tool loop.

Sibling of `vertex-ai/kubernetes/bridge/vertex_claude_bridge.py` — the translation
layer is deliberately identical so a fix to the tool loop applies to both. Only
transport and auth differ.

## 🔑 IAM

The bridge needs exactly two things, and no static credential:

```json
{
  "Effect": "Allow",
  "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
  "Resource": [
    "arn:aws:bedrock:us-east-1:<ACCOUNT>:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
    "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
    "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
    "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"
  ]
}
```

> ⚠️ **The three foundation-model ARNs are not redundant.** A `us.` inference profile
> is cross-region: Bedrock may route inference to any of those regions, and it
> authorizes against the profile ARN **and** the underlying foundation-model ARN in
> whichever region it lands. Grant only the profile and the first failover returns
> `AccessDeniedException` — intermittently, which makes it miserable to debug.

Managed for you by `aws/modules/hermes-eks-bedrock-iam` (EKS Pod Identity) or
`aws/modules/hermes-k3s` (EC2 instance profile).

## 💻 Local run

```bash
pip install -r requirements.txt
```

Credentials come from the standard chain, so any of an SSO profile, exported keys, or
an assumed role works:

```bash
export AWS_REGION=us-east-1 && export BEDROCK_CLAUDE_BRIDGE_API_KEY="$(openssl rand -hex 32)"
```

```bash
python3 bedrock_claude_bridge.py --host 127.0.0.1 --port 18182
```

Health — spends no tokens, by design (the readiness probe hits this every 10s):

```bash
curl -s -H "Authorization: Bearer $BEDROCK_CLAUDE_BRIDGE_API_KEY" http://127.0.0.1:18182/health
```

A real completion. Keep `max_tokens` small on a metered account:

```bash
curl -s -X POST http://127.0.0.1:18182/v1/chat/completions -H "Authorization: Bearer $BEDROCK_CLAUDE_BRIDGE_API_KEY" -H 'content-type: application/json' -d '{"max_tokens":16,"messages":[{"role":"user","content":"Reply with exactly: BRIDGE OK"}]}'
```

Tool-loop round trip — the part most worth testing, since it is where a translation
bug actually shows up:

```bash
curl -s -X POST http://127.0.0.1:18182/v1/chat/completions -H "Authorization: Bearer $BEDROCK_CLAUDE_BRIDGE_API_KEY" -H 'content-type: application/json' -d '{"max_tokens":128,"messages":[{"role":"user","content":"What is the status of pod web-1? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_pod","description":"Get a pod status","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}]}'
```

Expect `finish_reason: "tool_calls"` and a `tool_calls[0].function.arguments` string
containing valid JSON.

## 🔍 In-cluster validation

```bash
kubectl -n devops-agent logs hermes-agent-0 -c bedrock-claude-bridge | grep listening
```

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- sh -lc 'curl -sS -H "Authorization: Bearer $BEDROCK_CLAUDE_BRIDGE_API_KEY" http://127.0.0.1:18182/health'
```

Cache effectiveness. `cache_read` should dominate `cache_write` after the first call in
a thread; if it stays 0, something is invalidating the prefix (a changing system
prompt, a reordered tool list, a timestamp):

```bash
kubectl -n devops-agent logs hermes-agent-0 -c bedrock-claude-bridge | grep "usage model"
```

## ⚙️ Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `AWS_REGION` / `AWS_DEFAULT_REGION` / `BEDROCK_CLAUDE_REGION` | `us-east-1` | Bedrock region. **Required in-cluster** — the credential provider supplies credentials but no default region |
| `ANTHROPIC_MODEL` / `BEDROCK_CLAUDE_MODEL` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Model (inference profile) |
| `BEDROCK_CLAUDE_BRIDGE_API_KEY` | — | Bearer key callers must present. Empty disables auth (never do this in-cluster) |
| `BEDROCK_CLAUDE_ANTHROPIC_VERSION` | `bedrock-2023-05-31` | Bedrock's Anthropic version string (**not** Vertex's `vertex-2023-10-16`) |
| `BEDROCK_CLAUDE_MAX_TOKENS` | `4096` | Default output cap when the caller omits one |
| `BEDROCK_CLAUDE_TIMEOUT_SECONDS` | `300` | Per-request read timeout |
| `BEDROCK_CLAUDE_MAX_PROMPT_CHARS` | `200000` | Rejects oversized prompts with 413 before spending anything |
| `BEDROCK_CLAUDE_MAX_RETRIES` | `2` | Bounded backoff on transient Bedrock errors |
| `BEDROCK_CLAUDE_PROMPT_CACHING` | `1` | Explicit `cache_control` breakpoints. `0` disables |
| `BEDROCK_CLAUDE_CACHE_TTL` | `1h` | `1h`, `5m`, or `""` for no `ttl` field (Bedrock default 5m) |
| `BEDROCK_CLAUDE_THINKING_BUDGET_TOKENS` | `0` | Extended thinking. Sonnet 4.5 predates adaptive thinking, so this is the explicit-budget form; must be ≥1024 and < `max_tokens` |

## 🧠 Design notes

**Why `InvokeModel` and not `Converse`.** `Converse` normalizes across model families,
which means re-mapping Hermes's tool schema twice. `InvokeModel` takes the Anthropic
Messages body directly, so the translation is one hop and the same code as the Vertex
bridge.

**Why streaming is synthesized.** Bedrock's `InvokeModelWithResponseStream` emits an
event-stream shape that is not the chat-completions SSE Hermes expects. Rather than
maintain a second, divergent translation path, the bridge calls `InvokeModel` and wraps
the final message in chat-completions chunks. Hermes gets the shape it wants and the
tool-call translation stays identical between streaming and non-streaming.

**Why retries key on error code, not status.** Bedrock reports transient conditions as
modeled exceptions (`ThrottlingException`, `ServiceUnavailableException`,
`InternalServerException`, `ModelNotReadyException`, `ModelTimeoutException`), so
matching on HTTP status alone misses them. botocore's own retries are pinned to a
single attempt so the retry budget cannot silently multiply (3 × 3 = 9 calls).

**Why caching is explicit.** Bedrock supports Anthropic prompt caching but not
top-level *automatic* caching, so `cache_control: {type: ephemeral}` is placed by hand
on the stable prefix — last tool, system prompt, last message block. Max 4 breakpoints
exist; the bridge uses 3. The minimum cacheable prefix is ~1024 tokens, and shorter
prefixes silently do not cache.

**Why `/health` never invokes the model.** The readiness probe runs every 10s. A probe
that spent tokens would drain a metered allowance before anyone asked a question.
