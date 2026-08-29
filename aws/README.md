# 🚀 AWS EKS Blueprint - Terragrunt, Karpenter and EKS Auto-scaling

Opinionated, layered EKS blueprint driven entirely by **Terragrunt**. One set of
Terraform modules, one Terragrunt unit per layer, and Karpenter instead of
Cluster Autoscaler for node provisioning.

Tuned to run inside a **Pluralsight AWS cloud sandbox** without tripping any of
its guardrails - see [docs/sandbox/](docs/sandbox/).

---

## 🏗️ Architecture

```
                      ┌──────────────────────────────────────────┐
                      │  Terragrunt units (env/dev/us-east-1)    │
                      │                                          │
                      │   vpc  ──▶  eks  ──▶  karpenter          │
                      │        dependency    dependency          │
                      └──────────────────────────────────────────┘
                                        │  source
                                        ▼
                      ┌──────────────────────────────────────────┐
                      │  modules/{vpc,eks,karpenter,oidc}        │
                      └──────────────────────────────────────────┘

  VPC            10.60.0.0/16, 3 AZs, private + public tiers, single NAT
                 private subnets tagged karpenter.sh/discovery

  EKS            control plane (standard-support version, auto-upgrade on)
                 access entries (API auth mode) - no aws-auth ConfigMap
                 add-ons: vpc-cni, kube-proxy, coredns, pod-identity-agent,
                          metrics-server, ebs-csi (EKS Pod Identity)
                 system managed node group: on-demand t3.medium x2

  Karpenter      controller (Pod Identity), SQS interruption queue,
                 EC2NodeClass + NodePool (v1 APIs), consolidation on
```

Each layer is a separate state file. The `eks` unit consumes the `vpc` unit's
outputs through a Terragrunt `dependency` block, and `karpenter` consumes `eks`.

---

## 📂 Layout

```
modules/                    Terraform modules - no backend, no aws provider
├── vpc/                    network + subnet discovery tags
├── eks/                    control plane, add-ons, system node group, access
├── karpenter/              controller, IAM, queue, EC2NodeClass, NodePool
│   └── manifests/          inflate workload used to exercise scaling
├── alb-controller-iam/     IAM + Pod Identity for the AWS LB Controller
└── oidc/github/            GitHub Actions OIDC federation

terragrunt/
├── root.hcl                remote state, provider generation, retries
├── account.hcl             account id, state bucket, state KMS key
└── env/dev/
    ├── env.hcl             environment name, cluster name, k8s version
    └── region/us-east-1/
        ├── region.hcl
        ├── vpc/terragrunt.hcl
        ├── eks/terragrunt.hcl
        ├── karpenter/terragrunt.hcl
        ├── alb-controller-iam/terragrunt.hcl
        └── oidc/github/terragrunt.hcl

kubernetes/                 Helm add-ons and routing, each pinned and end-to-end tested
├── aws-load-balancer-controller/   ALB/NLB provisioning from Ingress + Service
├── alb-ingress/                    Ingress resources served by an ALB
├── traefik/                        Traefik v3 ingress behind an NLB
└── traefik-ingressroute/           IngressRoute + Middleware routing

terraform/                  standalone Kubernetes manifests and helper configs
                            (ArgoCD, Vault, EBS, legacy Karpenter)
docs/                       sandbox limits, bootstrap, Karpenter, testing
```

The modules are **not** root modules: they carry no `backend.tf` and no `aws`
provider block. Terragrunt generates both. That is what keeps a single copy of
each module usable across every environment and region.

---

## 📌 Versions

| Component | Version |
|---|---|
| Terraform | >= 1.10 |
| Terragrunt | >= 1.1 |
| AWS provider | ~> 6.0 |
| Helm provider | ~> 3.0 |
| `terraform-aws-modules/eks/aws` | ~> 21.25 |
| `terraform-aws-modules/vpc/aws` | ~> 6.7 |
| Kubernetes / EKS | 1.36 (standard support; `supportType = STANDARD`) |
| Karpenter | 1.14.1 (v1 APIs) |
| Node AMI | AL2023 |

---

## ✅ Prerequisites

- AWS credentials for the target account (`aws sts get-caller-identity`)
- Terraform, Terragrunt, kubectl and helm on `$PATH`
- A state bucket and KMS key - see [docs/bootstrap/](docs/bootstrap/)

Point `terragrunt/account.hcl` at your account id, bucket and key alias.

### ⚠️ Account: `637423440646` — IAM permissions

| Service | IAM | SCP | Result |
|---------|-----|-----|--------|
| **Bedrock** | ✅ `bedrock:*` (dedicated policy) | — | **Allowed** |
| **EKS** | ✅ `Allow` (via `NotAction` in `allow_all`) | ❌ **Deny** `eks:CreateCluster` (SCP `p-2nwbuy01`) | **Blocked** |
| **EC2, S3, IAM, VPC, etc.** | ✅ `Allow` | — | **Allowed** |
| **Lightsail** | ❌ Explicit deny in IAM | — | Blocked |
| **SageMaker** | ❌ Explicit deny in IAM | — | Blocked |

The `allow_all` policy grants all actions except `lightsail:*` and `sagemaker:*` via `NotAction`, so EKS is **IAM-allowed**. The SCP deny at the Organizations level overrides this. See [docs/sandbox/](docs/sandbox/) for details.

---

## ⚠️ EKS is blocked in Pluralsight sandboxes

`eks:CreateCluster` is denied by an AWS Organizations service control policy
(`o-yu55c2titn` / `p-2nwbuy01`) in both the regular and the AI Cloud Sandbox:

```text
AccessDeniedException: User: arn:aws:iam::<acct>:user/cloud_user is not authorized
to perform: eks:CreateCluster on resource: arn:aws:eks:us-east-1:<acct>:cluster/...
with an explicit deny in a service control policy
```

An SCP deny sits above the account. The IAM user *is* allowed the action by its own
identity policy — `aws iam simulate-principal-policy` returns `allowed`, because it
does not evaluate SCPs — but nothing inside a member account can override it, and
member accounts cannot read the policy. The deny is unconditional: verified across
Kubernetes 1.30/1.34/1.35/1.36 and the API default, both `authenticationMode`
values, tagged and untagged requests, EKS Auto Mode, `us-east-1` and `us-west-2`,
and multiple cluster names, in two separate sandbox accounts.

**Use the `hermes-k3s` unit instead** — a single-node k3s cluster on EC2, which the
sandbox does permit. It is a drop-in substitute: same VPC, same Kubernetes version
line, and every layer above the cluster is unchanged.

```bash
terragrunt apply --working-dir hermes-k3s
```

Deploy the `eks` unit only in an account whose SCP permits it. Everything else in
this blueprint — VPC, Karpenter, ALB controller IAM, OIDC — is unaffected.

## 🚢 Deploy

All deployment goes through Terragrunt. Run from
`terragrunt/env/dev/region/us-east-1`.

### 🎯 Which path? k3s vs EKS

| | k3s — **the sandbox path** | EKS |
|---|---|---|
| Units, in order | `vpc` → `hermes-k3s` | `vpc` → `eks` → `hermes-eks-bedrock-iam` |
| Traefik + Hermes | **automatic**, during the apply | manual, after the units |
| Bedrock credentials | EC2 instance profile | EKS Pod Identity |
| Works in a Pluralsight sandbox | ✅ | ❌ `eks:CreateCluster` denied by SCP |

`hermes-eks-bedrock-iam` is **EKS-only**. `hermes-k3s` already carries the same
Bedrock grant on its node instance profile, so do not apply both — the Pod Identity
association would fail with `ResourceNotFoundException: No cluster found`.

### 🚀 k3s path — two steps, then done

Run from `terragrunt/env/dev/region/us-east-1`.

```bash
terragrunt apply --working-dir vpc
```

```bash
terragrunt apply --working-dir hermes-k3s
```

That is the whole deployment: k3s, Traefik and the Hermes agent. The apply prints the
dashboard URL, username and generated password, and writes the kubeconfig to
`~/.kube/hermes-k3s`:

```bash
export KUBECONFIG=~/.kube/hermes-k3s && kubectl get pods -A
```

Details: [`hermes-k3s/README.md`](terragrunt/env/dev/region/us-east-1/hermes-k3s/README.md).

### Full command sequence

```bash
cd terragrunt/env/dev/region/us-east-1

# Phase 1: VPC
terragrunt apply --working-dir vpc

# Phase 2: EKS (requires eks:CreateCluster — SCP may block)
terragrunt apply --working-dir eks

# Phase 3: Karpenter (depends on EKS)
terragrunt apply --working-dir karpenter

# Phase 4: ALB Controller IAM (depends on EKS)
terragrunt apply --working-dir alb-controller-iam

# Phase 5: Hermes Bedrock IAM (depends on EKS)
terragrunt apply --working-dir hermes-eks-bedrock-iam

# Phase 6: Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name cloudgeeks-eks-dev
kubectl get nodes
```

> Phases 2-6 are the **EKS path**; see
> [`hermes-eks-bedrock-iam/README.md`](terragrunt/env/dev/region/us-east-1/hermes-eks-bedrock-iam/README.md)
> for what phase 5 grants and the manual steps that follow.

> **⚠️ Phase 2 may fail** with `AccessDeniedException` on `eks:CreateCluster` if your
> account's AWS Organizations SCP denies it. The IAM policy (`allow_all`) grants EKS
> via `NotAction`, but an SCP deny overrides it. See [docs/sandbox/](docs/sandbox/).

### Bulk apply (if all permissions are confirmed)

```bash
terragrunt run --all plan
terragrunt run --all apply
```

---

## 🔍 Verify

```bash
kubectl get nodes -L node.kubernetes.io/instance-type -L karpenter.sh/nodepool
```

```bash
kubectl get nodepool,ec2nodeclass
```

Exercise the autoscaler with the bundled probe:

```bash
kubectl apply -f modules/karpenter/manifests/inflate.yaml
```

```bash
kubectl scale deployment inflate --replicas 6
```

Karpenter should launch nodes within roughly a minute. Scaling back to zero
returns them after `consolidateAfter`.

For a realistic end-to-end test - CPU load driving the HPA, the HPA driving
Karpenter - use the load-testing suite, which has its own guardrails and
recorded timings: [load-testing/](load-testing/). Blueprint-wide validation
results are in [docs/testing/](docs/testing/).

---

## 🧹 Teardown

Reverse dependency order matters: Karpenter's nodes must go before the cluster,
or the node group delete blocks on orphaned instances.

```bash
terragrunt destroy --working-dir karpenter
```

```bash
terragrunt destroy --working-dir eks
```

```bash
terragrunt destroy --working-dir vpc
```

---

## 📚 Documentation

| Document | Contents |
|---|---|
| 🧪 [docs/sandbox/](docs/sandbox/) | Pluralsight sandbox limits and how the code encodes them |
| 🪣 [docs/bootstrap/](docs/bootstrap/) | State bucket and KMS key bootstrap |
| ⚡ [docs/karpenter/](docs/karpenter/) | NodePool/EC2NodeClass settings and production tuning |
| ⬆️ [docs/auto-upgrade/](docs/auto-upgrade/) | What EKS auto-upgrades (and what it does not, versus GKE) |
| 💾 [docs/backup-dr/](docs/backup-dr/) | AWS Backup for EKS, its gaps, and restore drills |
| 🔄 [docs/migration/](docs/migration/) | What changed from the previous revision and why |
| ✅ [docs/testing/](docs/testing/) | Validation procedure and recorded results |
| 🔥 [load-testing/](load-testing/) | HPA + Karpenter load test, commands and recorded results |
| ☸️ [kubernetes/](kubernetes/) | Ingress: AWS Load Balancer Controller, Traefik, and their routing resources |

Index: [docs/](docs/)
