# ☁️ Hermes Amazon Bedrock Deployment

Deployment of the **Hermes Lead SRE Agent** backed by **Amazon Bedrock Claude Sonnet
4.5**, running on the EKS blueprint in [`../aws/`](../aws/) behind **Traefik**.
Hermes runs with a custom `bedrock-claude-bridge` sidecar that translates its
chat-completions calls into Bedrock `InvokeModel` requests against the Anthropic
Messages API. This path uses no Claude Code CLI and no Claude subscription session.

```text
Target environment
  AWS account:  637423440646
  Region:       us-east-1
  EKS cluster:  cloudgeeks-eks-dev
  Model:        us.anthropic.claude-sonnet-4-5-20250929-v1:0
  Namespace:    devops-agent
  Ingress:      hermes.saqlainmushtaq.com  (Traefik IngressRoute, traefik-external)
  IAM:          allow_all (EKS allowed via NotAction; SCP denies eks:CreateCluster)
  Bedrock:      bedrock:* (dedicated whitelist policy)
```

Ported from [`../vertex-ai/`](../vertex-ai/) — the Hermes runtime configuration
is unchanged; see [What differs from the Vertex deployment](#-what-differs-from-the-vertex-deployment).

## 🗂️ Layout

```text
aws-bedrock/                  # sibling of vertex-ai/ — one directory per cloud provider
├── README.md                 # this file — architecture, security posture, Vertex delta
├── hermes/                   # the agent itself: Kustomize root, `kubectl apply -k hermes`
│   ├── bridge/               # bedrock_claude_bridge.py + requirements
│   ├── github-cli/           # read-only `gh` wrapper (fresh App token per call)
│   ├── identity/             # SOUL.md — the always-loaded agent identity
│   ├── skills/               # declaratively installed Hermes skills
│   │   ├── lead-devops-sre/        # greeting + capability profile
│   │   └── sre-pod-remediation/    # the scoped "fix a pod" disposition gate
│   ├── rbac/                 # namespaces, ServiceAccount, read-only + remediation RBAC
│   ├── secrets/              # secret.template.yaml (render with envsubst — never apply raw)
│   ├── storage/              # gp3 StorageClass
│   └── workloads/            # StatefulSet, Service, IngressRoute
├── overlays/k3s/             # patches the base for k3s (local-path, no gp3)
├── traefik/                  # k3s Traefik values, derived from aws/kubernetes/traefik
└── sre-demo/                 # a Deployment broken on purpose, for the fix demo
    ├── base/                 # the broken workload, shared by both overlays
    └── k3s/                  # the demo composed on the k3s overlay
```

**Every directory carries its own README** explaining what it does and the decisions
behind it — start at the one nearest whatever you are changing.

## 🧭 Relationship to the rest of the repo

```text
aws-bedrock/                Hermes on AWS Bedrock            <- this tree
vertex-ai/                  Hermes on Google Vertex AI       <- the deployment this is ported from
kubernetes/                 Hermes via the Claude Code CLI bridge, on GKE
aws/                        The Terragrunt AWS blueprint this runs on
hermes-agent-devops-demo/   The CLI-bridge flavour of the fix-a-pod demo (three gates)
```

## 📚 Documentation map

| Document | Scope |
| --- | --- |
| This file | Overview, architecture, bridge configuration, security posture, Vertex delta |
| [`hermes/README.md`](hermes/README.md) | **Deploy runbook** — infra prerequisites, apply flow, secrets, validation, DNS/TLS, troubleshooting |
| [`hermes/bridge/README.md`](hermes/bridge/README.md) | Bridge IAM, local dev, tool-loop testing, env reference, design rationale |
| [`hermes/rbac/README.md`](hermes/rbac/README.md) | Every grant and every deliberate denial, and how to verify the boundary |
| [`hermes/skills/README.md`](hermes/skills/README.md) | How skills are installed declaratively, and why a skill is a gate |
| [`hermes/identity/README.md`](hermes/identity/README.md) | `SOUL.md` — what belongs in identity vs a skill |
| [`hermes/workloads/README.md`](hermes/workloads/README.md) | StatefulSet/Service/IngressRoute, and the details that cost hours if changed carelessly |
| [`hermes/secrets/README.md`](hermes/secrets/README.md) | Required and optional Secrets; why there is no AWS credential |
| [`hermes/storage/README.md`](hermes/storage/README.md) | gp3 vs gp2, `WaitForFirstConsumer`, and the k3s difference |
| [`hermes/github-cli/README.md`](hermes/github-cli/README.md) | The read-only `gh` wrapper — per-call token minting and the allowlist |
| [`overlays/README.md`](overlays/README.md) | Cluster-flavour patches and why k3s needs so little |
| [`traefik/README.md`](traefik/README.md) | k3s Traefik values vs the EKS ones, install, verify |
| [`sre-demo/README.md`](sre-demo/README.md) | End-to-end: break a pod, have Hermes diagnose and fix it |

## 🏗️ Architecture

```text
                       hermes.saqlainmushtaq.com
                                 │
                        NLB (AWS LB Controller)
                                 │
                    Traefik v3 (traefik-external)
                                 │
                          IngressRoute
                    ┌────────────┴────────────┐
                 :9119                      :8642
              dashboard                    API /v1
                    └────────────┬────────────┘
                                 │
  ┌──────────────────────── pod: hermes-agent-0 ────────────────────────┐
  │  hermes                          bedrock-claude-bridge             │
  │  (gateway, dashboard,   ──127.0.0.1:18182──▶  (boto3, SigV4)       │
  │   MCP client, skills,                              │               │
  │   kubectl, gh)                                     │               │
  └────────────────────────────────────────────────────┼───────────────┘
                                                       ▼
                                     bedrock-runtime:InvokeModel
                                                       │
                                    us.anthropic.claude-sonnet-4-5
```

The pod runs **two** containers: `hermes` (gateway, dashboard, MCP client, skills) and
`bedrock-claude-bridge` (model bridge). There is no third auth-proxy sidecar — the
Vertex deployment's `gcp-mcp-auth-bridge` exists to work around Google MCP's OAuth
refresh problem, and Bedrock has no equivalent because Pod Identity credentials
refresh themselves.

GitHub access is provided by the read-only `gh` CLI installed in-pod (not an MCP
server). Kubernetes access is the pod's own ServiceAccount token.

## 🌉 The bedrock-claude-bridge

[`hermes/bridge/bedrock_claude_bridge.py`](hermes/bridge/bedrock_claude_bridge.py)
is a chat-completions-compatible HTTP shim:

* Exposes `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`.
* Translates Hermes tool definitions, tool calls, and tool results to and from the
  Anthropic Messages shape, preserving the full tool loop.
* Calls Bedrock `InvokeModel` with `anthropic_version: bedrock-2023-05-31`.
* For `stream: true`, calls `InvokeModel` and wraps the final response in
  chat-completions SSE chunks (Bedrock's `InvokeModelWithResponseStream` event shape
  differs from the SSE shape Hermes expects).
* Resolves Slack screenshot images from the cache under `/opt/data/image_cache`.
* Maps Bedrock's modeled exceptions to sensible HTTP statuses
  (`ValidationException` → 400, `AccessDeniedException` → 403,
  `ThrottlingException` → 429, …) instead of collapsing everything to a 502.

It runs as a pod-local sidecar, reachable only over `127.0.0.1` / ClusterIP, and
authenticates to AWS through the boto3 default credential chain, which in-cluster
resolves to **EKS Pod Identity** — the `hermes-agent` ServiceAccount is associated
with an IAM role carrying only `bedrock:InvokeModel` on the one configured model, so
credentials are keyless and short-lived. No access key anywhere.

### ⚠️ Claude Sonnet 4.5 is inference-profile-only on Bedrock

A bare `anthropic.claude-sonnet-4-5-20250929-v1:0` modelId is **rejected** with a
`ValidationException` telling you to use an inference profile:

```bash
aws bedrock list-foundation-models --region us-east-1 \
  --query "modelSummaries[?contains(modelId,'sonnet-4-5')].{id:modelId,inference:inferenceTypesSupported}"
# -> inference: ["INFERENCE_PROFILE"]
```

So the deployment uses the cross-region profile `us.anthropic.claude-sonnet-4-5-20250929-v1:0`.
That has an IAM consequence that costs people hours: a `us.` profile may route
inference to **us-east-1, us-east-2 or us-west-2**, and the policy must authorize the
underlying foundation model in *every* one of those regions plus the profile ARN
itself. Authorize only the profile and the first cross-region failover returns
`AccessDeniedException`. [`aws/modules/hermes-eks-bedrock-iam`](../aws/modules/hermes-eks-bedrock-iam)
does this correctly.

### ⚙️ Configuration

Set on the `bedrock-claude-bridge` container (see [`hermes/workloads/statefulset.yaml`](hermes/workloads/statefulset.yaml)):

| Variable | Production value | Purpose |
| --- | --- | --- |
| `AWS_REGION` | `us-east-1` | Bedrock region. **Required** — Pod Identity supplies credentials but no default region, so an unset value fails at startup with `NoRegionError` |
| `ANTHROPIC_MODEL` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Model (inference profile) |
| `BEDROCK_CLAUDE_BRIDGE_API_KEY` | (secret) | Bearer key Hermes uses to call the bridge |
| `BEDROCK_CLAUDE_MAX_TOKENS` | `8192` | Output cap |
| `BEDROCK_CLAUDE_TIMEOUT_SECONDS` | `300` | Per-request timeout |
| `BEDROCK_CLAUDE_PROMPT_CACHING` | `1` | Anthropic prompt caching (kill-switch: `0`) |
| `BEDROCK_CLAUDE_MAX_RETRIES` | `2` | Retry budget for transient Bedrock errors |
| `BEDROCK_CLAUDE_CACHE_TTL` | `1h` | Prompt-cache TTL — `1h` survives interactive thread gaps; `5m` for dense traffic; `""` to send no `ttl` and take Bedrock's 5m default |

`AWS_DEFAULT_REGION` and `BEDROCK_CLAUDE_REGION` / `BEDROCK_CLAUDE_MODEL` are also
accepted as aliases.

### 💰 Cost and reliability

* **Prompt caching.** Bedrock supports Anthropic prompt caching but has no top-level
  *automatic* caching, so the bridge sets `cache_control: {type: ephemeral}`
  explicitly on the stable prefix (last tool, system prompt, last message block),
  caching the large system + tools + history prefix. Minimum cacheable prefix is
  ~1024 tokens — shorter prefixes silently do not cache. Disable with
  `BEDROCK_CLAUDE_PROMPT_CACHING=0`.
* **Retries.** Bedrock reports transient conditions as modeled exceptions rather than
  bare status codes, so the bridge retries on error *code*
  (`ThrottlingException`, `ServiceUnavailableException`, `InternalServerException`,
  `ModelNotReadyException`, `ModelTimeoutException`) with bounded exponential
  backoff. botocore's own retries are pinned to a single attempt so the retry budget
  cannot multiply (3 × 3 = 9 silent calls).
* **Telemetry.** Every request logs token usage including cache hits:
  `[bedrock-claude-bridge] usage model=… input=… output=… cache_write=… cache_read=…`.
  Bedrock bills Claude Sonnet 4.5 at $3 / 1M input and $15 / 1M output; cache reads
  bill ≈ 0.1× input, cache writes ≈ 1.25×.
* **Health checks spend nothing.** `GET /health` deliberately does not invoke the
  model. The readiness probe runs every 10s; a probe that spent tokens would drain a
  sandbox's whole allowance before anyone asked a question.

## 🛠️ Scoped remediation — the agent can fix a pod

The Vertex deployment is strictly read-only. This one adds **one narrow exception**,
because "diagnose and hand back a command" is only half of what an SRE agent is for.

Two gates must both be open, and they are independent:

| Gate | What it controls | Where it lives |
| --- | --- | --- |
| **1 · RBAC** | Can the ServiceAccount perform the write at all? | [`hermes/rbac/clusterrole-sre-remediation.yaml`](hermes/rbac/clusterrole-sre-remediation.yaml) + a per-namespace RoleBinding |
| **2 · Skill** | Does Hermes's own disposition permit a write? | [`hermes/skills/sre-pod-remediation/SKILL.md`](hermes/skills/sre-pod-remediation/SKILL.md) |

The reference demo in [`../hermes-agent-devops-demo`](../hermes-agent-devops-demo)
needs a *third* gate — the Claude Code harness tool policy. **That gate does not
exist on this path**: Hermes talks to Bedrock through the bridge and runs `kubectl`
with its own `terminal` tool, so there is no `CLAUDE_CODE_ALLOWED_TOOLS` to open.
RBAC is therefore the only machine-enforced gate, which is exactly why it is scoped
per namespace here rather than cluster-wide.

**Authorized:** `rollout restart`, `set image`, `rollout undo`, `scale` on
Deployments, and `delete pod` — in namespaces carrying a `hermes-sre-remediation`
RoleBinding (shipped bound to **`demo`** only).

**Not authorized, anywhere:** Secrets (any verb), `create`/`delete` of Deployments,
StatefulSets/DaemonSets/Jobs/Services/ConfigMaps/PVCs, `kubectl exec`/`attach`/`cp`/
`port-forward`/`debug`/`run`, nodes, namespaces, RBAC, CRDs, webhooks, and every AWS
mutation other than `InvokeModel`.

The ClusterRole grants nothing by itself — a `RoleBinding` (not a
`ClusterRoleBinding`) scopes it to one namespace, so the blast radius is exactly the
namespaces you opt in. Revoking is `kubectl delete rolebinding hermes-sre-remediation -n demo`;
the read-only base is untouched.

Walk it end to end: [`sre-demo/README.md`](sre-demo/README.md).

## 🐙 Read-only GitHub CLI (`kubernetes/github-cli/`)

`github-cli/gh` is a POSIX-shell wrapper that replaces a GitHub MCP server. It is
symlinked to `/usr/local/bin/gh` in the `hermes` container (postStart hook) and does
two jobs on **every call**:

1. **Mints a fresh GitHub App installation token.** App tokens expire after ~1 hour;
   a server that mints once at startup starts returning `401 Bad credentials` an hour
   later. Per-call minting (JWT signed with the App key → installation access token)
   makes that failure mode impossible.
2. **Enforces a read-only allowlist.** `repo`/`pr`/`issue`/`run`/`workflow`/`release`/
   `label`/`gist` allow only `list|view|diff|checks|download|status`; `search`/`status`
   pass; `gh api` allows only `GET`/`HEAD` and denies every body/field flag
   (`-f`/`-F`/`--field`/`--raw-field`/`--input`). Everything else exits 64 with
   `blocked by the read-only SRE policy`.

The `hermes-agent-github-app` Secret is **optional** in this deployment (unlike the
Vertex one): the Secret volume and both env vars are marked `optional: true`, so the
pod starts on a cluster with no GitHub App configured and `gh` is simply
unauthenticated until you create the Secret and roll the StatefulSet. Setup commands
are in [`hermes/README.md`](hermes/README.md).

## 🔒 Security posture

* **EKS Pod Identity** — the `hermes-agent` ServiceAccount is associated with a
  dedicated IAM role carrying only `bedrock:InvokeModel` /
  `InvokeModelWithResponseStream` on the single configured model, plus read-only
  model-discovery calls. No access key in Git or in a Kubernetes Secret, and — unlike
  IRSA — no OIDC trust policy to hand-maintain and no ServiceAccount annotation to
  keep in sync.
* **Read-only by default, with one audited exception.** Kubernetes reads are
  cluster-wide; writes exist only in namespaces explicitly bound to the scoped
  remediation ClusterRole. GitHub is read-only (App scope + wrapper allowlist). AWS
  is invoke-only. Secrets are absent from every rule, so they fail at the API server
  even if the model is prompt-injected.
* **Runtime hardening.** The agent runs only the tools baked in via the init
  containers and cannot execute arbitrary code or install anything at runtime:
  `agent.disabled_toolsets: [code_execution]` (no arbitrary Python / `execute_code`)
  and `security.allow_lazy_installs: false` (no on-the-fly package/binary installs),
  a `block-installs` pre_tool_call hook, `uv` removed, plus non-root (uid 10000),
  `allowPrivilegeEscalation: false`, and `NET_RAW`/`NET_ADMIN` dropped.
* **Cost optimization** — `agent.max_turns: 60`,
  `tool_loop_guardrails.hard_stop_enabled: true`, and all bundled skills stripped
  (`hermes skills opt-out --remove`; only the two local skills remain → smaller
  system prompt). Prompt caching + retries in the bridge (above).
* The bridge is never exposed publicly; it listens on a pod-local port behind the
  bridge API key. The `Service` publishes port 18182 for in-cluster debugging only —
  the IngressRoute never routes to it.

## 🔀 What differs from the Vertex deployment

Everything in the Hermes runtime config — the provider block, compaction threshold,
tool-search off, Playwright MCP, block-installs hook, skill stripping, `max_turns` —
is carried over unchanged. The deltas are all forced by the platform, except the last
two which are deliberate:

| | Vertex AI / GKE | Bedrock / EKS |
| --- | --- | --- |
| Model | `claude-opus-4-8` (Claude sidecar) / `gemini-3.5-flash` (deployed default) | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| Anthropic version | `vertex-2023-10-16` | `bedrock-2023-05-31` |
| Transport | `AuthorizedSession` → `:rawPredict` | boto3 `InvokeModel` + SigV4 |
| Auth | GKE Workload Identity (SA annotation → GSA) | EKS Pod Identity (association, **no SA annotation**) |
| Auth dependency | `google-auth`, `requests` | `boto3` |
| Model id form | Bare model name | **Inference profile required** (`us.` prefix) |
| Region | `global` multi-region | `us-east-1` (+ cross-region profile failover) |
| StorageClass | `standard-rwo` | `gp3` (declared in `storage/`) |
| Load balancer | GKE LB → Traefik | NLB via AWS Load Balancer Controller → Traefik |
| Observability MCP | 3 read-only GCP MCPs + `gcp-mcp-auth-bridge` sidecar | **None** — no AWS equivalent wired; kubectl + the console instead |
| Context window pin | `1000000` | `200000` (Sonnet 4.5's default on Bedrock; the 1M window is a separate opt-in) |
| I/O limits | 150000 B / 5000 lines / 300000 chars | 60000 B / 2500 lines / 120000 chars — scaled to the 200k window |
| GitHub App Secret | Required (pod blocks without it) | **Optional** (`optional: true`) |
| Write access | None — strictly read-only | **Scoped remediation** in bound namespaces |

## ⚠️ Bedrock model access is per-account — Sonnet 4.5 may be unavailable

Claude Sonnet 4.5 is this deployment's designed default and remains the default in the
base manifests. **Some Pluralsight AI sandbox accounts are provisioned without an AWS
Marketplace subscription for it**, and the subscription cannot be added from inside the
account:

```text
InvokeModel                    -> AccessDeniedException: Model access is denied ...
                                  required AWS Marketplace actions
                                  (aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe)

CreateFoundationModelAgreement -> AccessDeniedException ... explicit deny in a
                                  service control policy: p-sdxy6x4w
```

The second deny is decisive: accepting the model agreement is precisely how you would
clear the first, and a *different* SCP forbids it — matching the sandbox documentation's
"Cannot enable or modify model access agreements".

**Diagnose it correctly.** The same error appears for the account's own IAM user, which
carries `allow_all`. That proves it is account-level model access, **not** a gap in the
agent's role policy — do not go rewriting the IAM module:

```bash
aws bedrock-runtime invoke-model --model-id us.anthropic.claude-sonnet-4-5-20250929-v1:0 --content-type application/json --accept application/json --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' /dev/stdout
```

Find what the account *can* invoke — access varies between sandbox instances:

```bash
for m in us.anthropic.claude-sonnet-4-5-20250929-v1:0 us.anthropic.claude-haiku-4-5-20251001-v1:0 anthropic.claude-3-haiku-20240307-v1:0; do echo "$m"; done
```

**Fallback:** Claude Haiku 4.5 is subscribed where Sonnet 4.5 is not, and shares its 200k
context window — so the `context_length` pin and I/O limits need no change. Switching
takes **two** coordinated edits, because the node role authorizes one specific model:

1. `model_id` / `foundation_model_id` in `../aws/terragrunt/env/dev/region/us-east-1/hermes-k3s/terragrunt.hcl`, then `terragrunt apply` (updates the IAM policy in place — no instance replacement).
2. `kubectl apply -k overlays/k3s-haiku-4-5` instead of `overlays/k3s`.

Change only one and `InvokeModel` fails with `AccessDeniedException` on the ARN.

Neither `SOUL.md` nor the skills hardcode a model version — the agent cannot introspect
what the bridge is bound to, so a hardcoded version would silently drift. The manifest is
the single source of truth.

## ⚠️ EKS SCP denial — current state

The sandbox's AWS Organizations SCP (`p-2nwbuy01`) explicitly denies `eks:CreateCluster`.

**IAM permissions are correct** — the `allow_all` policy grants EKS via `NotAction` (confirmed via `simulate-principal-policy`). The SCP deny overrides this at the Organizations level and **cannot be bypassed from within the account**.

Verified denied across: all Kubernetes versions (1.30–1.36), both `authenticationMode` values, tagged/untagged, EKS Auto Mode, both regions, and two cluster names. No cluster is pre-provisioned in any region.

**Resolution:** The Pluralsight/org admin must modify SCP `p-2nwbuy01` to allow `eks:CreateCluster`. Member accounts cannot read or modify the policy.

**Current deployment:** Uses [`aws/modules/hermes-k3s`](../aws/modules/hermes-k3s/) as a drop-in substitute. `ec2:RunInstances` at `t3.medium` is permitted. The EKS path in `modules/eks` is fully functional and should be used once the SCP is lifted — everything layered above the cluster is identical either way.

## 🛠️ Deployment

Infra first, then the agent — the full runbook is in
[`hermes/README.md`](hermes/README.md):

```bash
# 1. Infra (Terragrunt)
#      vpc  ->  eks + hermes-eks-bedrock-iam      (when SCP permits eks:CreateCluster)
#      vpc  ->  hermes-k3s                    (current: SCP blocks EKS)
# 2. Traefik   pinned chart 41.3.0, CRDs first, traefik-external IngressClass
# 3. Secrets   envsubst < hermes/secrets/secret.template.yaml | kubectl apply -f -
# 4. Agent     kubectl apply -k hermes        (EKS)
#              kubectl apply -k overlays/k3s  (k3s)
# 5. Demo      kubectl apply -k sre-demo/k3s
```

### IAM summary (account `637423440646`)

| Permission | Source | Status |
|---|---|---|
| `bedrock:*` | Dedicated `bedrock-model-whitelist` policy | ✅ Allowed |
| `eks:CreateCluster` | `allow_all` (NotAction) | ✅ IAM allowed, ❌ SCP denied |
| `ec2:RunInstances` | `allow_all` | ✅ Allowed |
| `lightsail:*` | Explicit deny in `allow_all` | ❌ Blocked |
| `sagemaker:*` | Explicit deny in `allow_all` | ❌ Blocked |

## ✅ Verified deployed state

Deployed and validated end to end in account `637423440646` / `us-east-1`:

| Check | Result |
| --- | --- |
| Remote state | S3 bucket + KMS CMK, versioned, TLS-only, encryption-enforced |
| VPC | `vpc-072a29fa3d5fc6a01`, 10.60.0.0/16, 3 AZs, single NAT |
| Cluster | k3s **v1.36.3** on `t3.medium`, Ready (EKS blocked by SCP) |
| Traefik | chart 41.3.0, `traefik-external` IngressClass, public 80/443 via klipper |
| Hermes pod | `hermes-agent-0` **2/2 Running** |
| Bridge | listening on `:18182`, model `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| Bedrock auth | instance profile via IMDS (hop limit 2) — **no static credential** |
| End-to-end inference | `POST /v1/chat/completions` → `BRIDGE OK`, correct chat-completions shape |
| Ingress | `https://hermes.saqlainmushtaq.com/health` → `200 {"status":"ok"}`; `/` → `302` to dashboard login |
| Prompt caching | 96,931 tokens cache-read vs 21,869 cache-write; 40 uncached input tokens |
| RBAC allow | `patch deployments`, `delete pods`, `update deployments/scale` in `demo`; reads cluster-wide |
| RBAC deny | writes in `devops-agent`/`kube-system`, `get secrets`, `create`/`delete deployments`, `pods/exec` |
| SRE demo | Hermes diagnosed `nginx:faulty` → applied `set image` → rollout 1/1 |

DNS for `hermes.saqlainmushtaq.com` still needs an A record at the node IP, and the
IngressRoute serves Traefik's self-signed certificate until cert-manager or the
Cloudflare proxy fronts it — see
[`hermes/README.md`](hermes/README.md) → **DNS and TLS**.
