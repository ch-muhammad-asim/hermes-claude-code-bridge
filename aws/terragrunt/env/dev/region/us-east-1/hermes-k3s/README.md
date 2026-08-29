# ☸️ `hermes-k3s` — the deploy step for this sandbox

Provisions a single-node k3s cluster on EC2 **and** deploys Traefik + the Hermes agent
onto it. One command, and it returns only when the stack actually works.

## ✅ Steps

Run from `aws/terragrunt/env/dev/region/us-east-1`.

**Step 1 — network** (skip if the VPC already exists):

```bash
terragrunt apply --working-dir vpc
```

**Step 2 — cluster + Traefik + Hermes:**

```bash
terragrunt apply --working-dir hermes-k3s
```

**Done.** That is the whole deployment. The apply prints:

```text
════════════════════════════════════════════════════════════════════
 Hermes on k3s is ready
════════════════════════════════════════════════════════════════════
 Dashboard   https://hermes.saqlainmushtaq.com/
 Username    admin
 Password    <generated>
 Node IP     <public ip>
 Kubeconfig  /Users/<you>/.kube/hermes-k3s
════════════════════════════════════════════════════════════════════
```

The kubeconfig is downloaded to your machine automatically (mode `0600`, context
renamed `hermes-k3s`):

```bash
export KUBECONFIG=~/.kube/hermes-k3s && kubectl get pods -A
```

Re-read the credentials any time without re-applying:

```bash
terragrunt output --working-dir hermes-k3s dashboard_password
```

## 🚫 You do NOT need `hermes-eks-bedrock-iam` here

That unit grants Bedrock access through an **EKS Pod Identity association**, which
requires an EKS cluster. There is no EKS cluster on this path — and
`eks:CreateCluster` is denied by an org SCP in Pluralsight sandboxes anyway.

`hermes-k3s` already carries the identical Bedrock grant on the node's **EC2 instance
profile** (`aws_iam_instance_profile.node`, statement `InvokeConfiguredClaudeModel`),
so applying `hermes-eks-bedrock-iam` would add a duplicate role and then **fail** at
`aws_eks_pod_identity_association` with `ResourceNotFoundException: No cluster found`.

| Path | Units, in order | Bedrock credentials from |
|---|---|---|
| **k3s** (this sandbox) | `vpc` → `hermes-k3s` | EC2 instance profile |
| **EKS** (where the SCP permits) | `vpc` → `eks` → `hermes-eks-bedrock-iam` | EKS Pod Identity |

## ⏱️ What happens during the apply

The node bootstraps itself and reports progress to S3; Terraform polls it and fails
the apply if it never completes:

```text
waiting for i-… to finish bootstrapping (timeout 20m)...
  status: RUNNING
  status: K3S_READY
  status: TRAEFIK_READY
  status: SECRETS_READY
  status: COMPLETE
bootstrap complete
```

Typical time: **4–8 minutes**.

## ⚙️ Before you apply

- `api_allowed_cidrs` pins the Kubernetes API to your egress `/32`. It defaults to
  empty, which creates **no rule at all** — failing closed (no kubectl) rather than
  exposing 6443. Update it when your network changes:

  ```bash
  curl -s https://checkip.amazonaws.com
  ```

- `hermes_overlay` **must match** `model_id`. The node role authorizes exactly one
  model, so a mismatch fails at `InvokeModel` with `AccessDeniedException`:

  | `model_id` | `hermes_overlay` |
  |---|---|
  | `us.anthropic.claude-sonnet-4-5-…` | `aws-bedrock/overlays/k3s` |
  | `us.anthropic.claude-haiku-4-5-…` | `aws-bedrock/overlays/k3s-haiku-4-5` |

  This sandbox has no Marketplace subscription for Sonnet 4.5, so it is pinned to
  Haiku 4.5.

- `manifests_ref` is the Git ref the node clones. It is `main`, so **push your
  manifest changes before applying** or the node deploys the old ones.

## 🧯 If an apply is interrupted

Terragrunt leaves an S3 lock behind, and the next apply fails with
`PreconditionFailed 412` rather than an obvious "locked" message. Read the lock id
and clear it:

```bash
aws s3 cp s3://<state-bucket>/env/dev/region/us-east-1/hermes-k3s/terraform.tfstate.tflock -
```

```bash
terragrunt run --working-dir hermes-k3s -- force-unlock -force <LOCK_ID>
```

Full module reference — cluster access, credentials, troubleshooting:
[`aws/modules/hermes-k3s/README.md`](../../../../../../modules/hermes-k3s/README.md).
