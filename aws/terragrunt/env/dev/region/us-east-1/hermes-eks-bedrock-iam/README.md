# 🔑 `hermes-eks-bedrock-iam` — Bedrock access for the **EKS** path

Grants the Hermes agent invoke-only access to one Bedrock model through an **EKS Pod
Identity association**: an IAM role, a narrow policy, and a binding to the
`devops-agent/hermes-agent` ServiceAccount.

> ⚠️ **This unit is for the EKS path only.** It requires a live EKS cluster. If you
> are deploying on k3s — which is what Pluralsight sandboxes force — **skip it**; see
> [Which path am I on?](#-which-path-am-i-on) below.

## ✅ Steps (EKS path)

Run from `aws/terragrunt/env/dev/region/us-east-1`.

**Step 1 — network:**

```bash
terragrunt apply --working-dir vpc
```

**Step 2 — cluster:**

```bash
terragrunt apply --working-dir eks
```

**Step 3 — Bedrock access:**

```bash
terragrunt apply --working-dir hermes-eks-bedrock-iam
```

**Step 4 — point kubectl at the cluster:**

```bash
aws eks update-kubeconfig --region us-east-1 --name cloudgeeks-eks-dev
```

**Step 5 — deploy Traefik, the Secrets and the agent.** Unlike the k3s path, none of
this is automated here — there is no `user_data` to do it. Follow
[`aws-bedrock/hermes/README.md`](../../../../../../../aws-bedrock/hermes/README.md)
steps 2–4.

## 🧭 Which path am I on?

| | k3s | EKS |
|---|---|---|
| Units | `vpc` → `hermes-k3s` | `vpc` → `eks` → `hermes-eks-bedrock-iam` |
| This unit | **not used** | required |
| Bedrock credentials | EC2 instance profile | EKS Pod Identity |
| Traefik + Hermes | automatic, during `terragrunt apply` | manual, after the units |

`hermes-k3s` already carries the identical Bedrock grant on its node instance
profile, so applying this unit alongside it would create a duplicate role and then
**fail** at `aws_eks_pod_identity_association`:

```text
ResourceNotFoundException: No cluster found for name: cloudgeeks-eks-dev
```

Note the plan looks clean before that — the `eks` unit still outputs a
`cluster_name` even when the cluster was never created, so `terragrunt plan` reports
`Plan: 5 to add` and the failure only surfaces at apply.

## 🚫 EKS is blocked in Pluralsight sandboxes

Step 2 above cannot succeed there. `eks:CreateCluster` is denied by an AWS
Organizations SCP (`p-2nwbuy01`) — an org-level explicit deny that a member account
cannot override, and one that is unconditional across every Kubernetes version, both
auth modes, tagged requests, EKS Auto Mode, and both permitted regions. Use
[`hermes-k3s`](../hermes-k3s/) instead.

## 🔐 What it grants

| Statement | Actions | Scope |
|---|---|---|
| `InvokeConfiguredClaudeModel` | `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream` | The configured inference profile **plus** the underlying foundation model in every region a cross-region (`us.`) profile can route to |
| `DescribeModelsForHealthChecks` | `bedrock:List*`/`Get*` foundation models and inference profiles | `*` — read-only, and spends no tokens |

Nothing else: no model-access management, no Bedrock Agents, no Knowledge Bases.

> The multiple foundation-model ARNs are not redundant. A `us.` profile is
> cross-region; authorize only the profile and the first failover returns
> `AccessDeniedException` — intermittently, which is miserable to debug.

`namespace` and `service_account` must match `aws-bedrock/hermes/rbac/serviceaccount.yaml`,
or Pod Identity never binds and the bridge fails with `AccessDeniedException` on
`InvokeModel`.
