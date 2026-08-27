# ☸️ Hermes + Bedrock — Kubernetes deploy runbook

This directory is the **self-contained Kustomize root** for the Hermes + Bedrock
deployment: `kubectl apply -k .` renders and applies the whole stack.

```text
Target environment
  AWS account:  381491923945
  Region:       us-east-1
  Model:        us.anthropic.claude-sonnet-4-5-20250929-v1:0
  Namespace:    devops-agent
  Ingress:      hermes.saqlainmushtaq.com
```

## 🗂️ Directory layout

```text
kubernetes/
├── kustomization.yaml        # the Kustomize root — apply with `kubectl apply -k .`
├── bridge/                   # bedrock_claude_bridge.py + requirements (+ local-dev README)
├── github-cli/               # read-only `gh` wrapper (fresh App token per call)
├── identity/                 # SOUL.md — the agent's always-loaded identity
├── skills/                   # version-controlled Hermes skills (declaratively installed)
│   ├── lead-devops-sre/           # greeting + capability profile
│   └── sre-pod-remediation/       # the scoped "fix a pod" disposition gate
├── rbac/                     # namespaces, ServiceAccount, read-only RBAC, remediation RBAC
├── secrets/                  # secret.template.yaml (render with envsubst — never apply raw)
├── storage/                  # gp3 StorageClass
└── workloads/                # StatefulSet, Service, IngressRoute
```

## ⚠️ Which cluster? EKS vs k3s

The base targets **EKS**. If your account's SCP denies `eks:CreateCluster` — which the
Pluralsight **AI** Cloud Sandbox does (`p-2nwbuy01`, an AWS Organizations explicit
deny that a member account cannot override, confirmed unconditional across every
supported Kubernetes version, both auth modes, tagged requests and EKS Auto Mode) —
use the k3s path instead:

| | EKS | k3s (sandbox fallback) |
| --- | --- | --- |
| Infra unit | `terragrunt apply --working-dir eks` + `hermes-bedrock-iam` | `terragrunt apply --working-dir hermes-k3s` |
| Bedrock credentials | EKS Pod Identity association | EC2 instance profile (IMDS) |
| Apply | `kubectl apply -k hermes` | `kubectl apply -k overlays/k3s` |
| StorageClass | `gp3` (ebs.csi.aws.com) | `local-path` (patched by the overlay) |
| Ingress LB | NLB via AWS Load Balancer Controller | k3s servicelb (klipper) binding host 80/443 |

**The bridge is byte-identical on both.** boto3's default credential chain resolves
Pod Identity on EKS and IMDS on EC2, so nothing in the application changes.

## ✅ Runtime requirements

- Claude Sonnet 4.5 access in Bedrock for the account. Check without spending tokens:
  ```bash
  aws bedrock list-inference-profiles --region us-east-1 \
    --query "inferenceProfileSummaries[?contains(inferenceProfileId,'sonnet-4-5')].{id:inferenceProfileId,status:status}"
  ```
  Note `inferenceTypesSupported` on the foundation model is `["INFERENCE_PROFILE"]` —
  a bare `anthropic.claude-sonnet-4-5-*` modelId is rejected with a
  `ValidationException`. Always use the `us.` profile id.
- A Kubernetes cluster (see above) with the Traefik controller watching the
  `traefik-external` IngressClass.
- On EKS: the `eks-pod-identity-agent` add-on (installed by `aws/modules/eks`) and the
  `hermes-bedrock-iam` Terragrunt unit applied.
- On EC2/k3s: `http_put_response_hop_limit = 2` on the instance's metadata options.
  **This is not optional** — pod traffic to IMDS traverses the host network namespace
  and decrements the hop count, so at the default limit of 1 every pod gets a
  connection timeout instead of credentials and the bridge dies with
  `NoCredentialsError`.

---

## 1️⃣ Infrastructure (Terragrunt)

All infra goes through Terragrunt from `aws/terragrunt/env/dev/region/us-east-1`.

Bootstrap remote state once (`aws/docs/bootstrap/README.md`), point
`aws/terragrunt/account.hcl` at your account id and bucket, then:

```bash
terragrunt apply --working-dir vpc
```

**EKS path:**

```bash
terragrunt apply --working-dir eks
```

```bash
terragrunt apply --working-dir hermes-bedrock-iam
```

```bash
aws eks update-kubeconfig --region us-east-1 --name cloudgeeks-eks-dev
```

**k3s path** (when EKS is denied). The unit pins the Kubernetes API to your egress
`/32` — an empty `api_allowed_cidrs` creates no rule at all, so a forgotten value
fails closed rather than exposing 6443:

```bash
terragrunt apply --working-dir hermes-k3s
```

The node publishes its kubeconfig to S3 (a single-object `s3:PutObject` grant), so
reaching the cluster needs no SSH key and no inbound port 22:

```bash
aws s3 cp s3://cloudgeeks-eks-blueprints-tfstate-381491923945/k3s/kubeconfig $HOME/.kube/hermes-k3s --region us-east-1 && chmod 600 $HOME/.kube/hermes-k3s && export KUBECONFIG=$HOME/.kube/hermes-k3s
```

```bash
kubectl get nodes -o wide
```

## 2️⃣ Traefik

Everything is driven by a single `CHART_VERSION` so the CRDs and the chart cannot
drift apart:

```bash
export CHART_VERSION=41.3.0
```

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update
```

CRDs first, pinned to the same chart version — always before the chart, or the
IngressRoute kind does not exist yet:

```bash
helm show crds traefik/traefik --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
```

EKS (NLB via the AWS Load Balancer Controller — install that first, see
`aws/kubernetes/aws-load-balancer-controller/README.md`):

```bash
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" --create-namespace --values ../../aws/kubernetes/traefik/eks-values.yaml --wait --timeout 6m
```

k3s (no LB controller; klipper binds host 80/443):

```bash
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" --create-namespace --values ../traefik/k3s-values.yaml --wait --timeout 6m
```

Confirm the IngressClass the IngressRoute names actually exists — an
`ingressClassName` no controller watches is silently never picked up:

```bash
kubectl get ingressclass
```

## 3️⃣ Secrets

Bedrock needs **no** credential here — that is the point of Pod Identity / the
instance profile. Only the Hermes-internal secrets are required.

```bash
export NAMESPACE=devops-agent
```

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

```bash
export BEDROCK_CLAUDE_BRIDGE_API_KEY="$(openssl rand -hex 32)" && export HERMES_DASHBOARD_PASSWORD="$(openssl rand -hex 16)" && echo "dashboard password: $HERMES_DASHBOARD_PASSWORD"
```

Hash the dashboard password **with the exact image the StatefulSet runs**, or the hash
is produced by a different build than the one verifying it. Running it as a pod avoids
needing a local Docker daemon; `--rm -it` can time out on the first pull, so create,
wait, then read the log:

```bash
kubectl -n "$NAMESPACE" run hashgen --restart=Never --image=nousresearch/hermes-agent:v2026.8.3 --env="HERMES_DASHBOARD_PASSWORD=$HERMES_DASHBOARD_PASSWORD" --env="PYTHONPATH=/opt/hermes" --command -- /opt/hermes/.venv/bin/python -c 'import os; from plugins.dashboard_auth.basic import hash_password; print("HASH="+hash_password(os.environ["HERMES_DASHBOARD_PASSWORD"]))'
```

```bash
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/hashgen --timeout=420s
```

```bash
export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$(kubectl -n "$NAMESPACE" logs hashgen | sed -n 's/^HASH=//p')" && kubectl -n "$NAMESPACE" delete pod hashgen
```

```bash
export API_SERVER_KEY="$(openssl rand -hex 32)" && export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)"
```

```bash
envsubst < secrets/secret.template.yaml | kubectl apply -f -
```

## 4️⃣ Apply the agent

EKS:

```bash
kubectl apply -k .
```

k3s:

```bash
kubectl apply -k ../overlays/k3s
```

```bash
kubectl -n devops-agent rollout status statefulset/hermes-agent --timeout=600s
```

## 5️⃣ Validate

Both containers Ready, and the bridge bound to the right model:

```bash
kubectl -n devops-agent get pod hermes-agent-0
```

```bash
kubectl -n devops-agent logs hermes-agent-0 -c bedrock-claude-bridge | grep listening
```

The Hermes API through Traefik. Substitute the node/LB address for `--resolve` if DNS
is not pointed yet:

```bash
curl -sk --resolve hermes.saqlainmushtaq.com:443:<NODE_IP> https://hermes.saqlainmushtaq.com/health
```

End-to-end through the bridge to Bedrock. This **spends tokens** — keep `max_tokens`
tiny on a sandbox:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- sh -lc 'curl -sS -X POST http://127.0.0.1:18182/v1/chat/completions -H "Authorization: Bearer $BEDROCK_CLAUDE_BRIDGE_API_KEY" -H "content-type: application/json" -d "{\"max_tokens\":12,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: BRIDGE OK\"}]}"'
```

Token accounting, including cache effectiveness — if `cache_read` stays 0 across
repeated calls, something is invalidating the prefix:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c bedrock-claude-bridge | grep "usage model"
```

RBAC boundaries. The first four must be `yes`, the rest `no`:

```bash
kubectl auth can-i patch deployments -n demo --as=system:serviceaccount:devops-agent:hermes-agent
```

```bash
for q in "patch deployments -n devops-agent" "get secrets -n demo" "create deployments -n demo" "create pods/exec -n demo"; do echo "$q -> $(kubectl auth can-i ${=q} --as=system:serviceaccount:devops-agent:hermes-agent)"; done
```

## 🌐 DNS and TLS

Point an **A record** for `hermes.saqlainmushtaq.com` at the ingress address:

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0]}'
```

On k3s that address is the node's public IP; on EKS it is the NLB hostname (use a
CNAME there instead).

**TLS:** the IngressRoute declares `tls: {}` with no `certResolver`, so Traefik serves
its built-in **self-signed** certificate — browsers will warn, and `curl` needs `-k`.
For a trusted certificate pick one of:

- **Cloudflare proxy** (orange cloud) in front, SSL mode *Full* — the quickest, and it
  also hides the node IP.
- **cert-manager + Let's Encrypt**, then reference the issued Secret from the
  IngressRoute's `tls.secretName`.

Do not leave a public dashboard on a self-signed cert longer than a demo.

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Bridge exits `NoCredentialsError` / `NoRegionError` | On EC2: IMDS hop limit is 1, so pods cannot reach it. Or `AWS_REGION` unset | Set `http_put_response_hop_limit = 2`; `AWS_REGION` is set on the sidecar in the manifest |
| `AccessDeniedException` on InvokeModel | Pod Identity association missing, or the policy omits the cross-region foundation-model ARNs a `us.` profile fails over to | Apply `hermes-bedrock-iam`; confirm all three regions are in the policy |
| `ValidationException: ... use an inference profile` | A bare foundation-model id was used | Use `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| PVC stuck `Pending` | `gp3` StorageClass on a cluster without the EBS CSI driver (e.g. k3s) | Apply `overlays/k3s`, which switches it to `local-path` |
| Pod stuck `ContainerCreating` on a missing Secret | Only `hermes-agent-secrets` is mandatory | Create it (step 3); the GitHub App Secret is `optional: true` |
| IngressRoute never routes | `ingressClassName` names a class no controller watches | `kubectl get ingressclass` and align |
| 404 from Traefik on the right host | IngressRoute in a namespace Traefik does not watch, or Host rule mismatch | Check `kubectl -n devops-agent describe ingressroute hermes-agent-dashboard` |
| `ThrottlingException` in bridge logs | Account-level Bedrock TPM/RPM quota | The bridge already retries; lower concurrency or request a quota increase |

## 🔒 Security hardening

- Non-root (uid 10000), `allowPrivilegeEscalation: false`, `NET_RAW`/`NET_ADMIN` dropped.
- `agent.disabled_toolsets: [code_execution]` — no arbitrary Python / `execute_code`.
- `security.allow_lazy_installs: false` plus a `block-installs` pre_tool_call hook and
  `uv` removed — the agent runs only the binaries the init containers baked in.
- Read-only RBAC cluster-wide; writes only in namespaces bound to
  `hermes-sre-remediation`. Secrets appear in no rule, so they fail at the API server
  even under prompt injection.
- AWS access is invoke-only on one model. There is no AWS CLI in the pod.
