# 🔄 What changed, and why

The previous revision of this blueprint was built around EKS module v19, the
`aws-auth` ConfigMap, Cluster Autoscaler and Karpenter's v1alpha5 APIs. All
four are now either removed upstream or actively harmful to carry forward.

## 🏗️ Structural

**One copy of each module.** `terraform/vpc` and `terragrunt/modules/vpc` were
two diverging copies of the same module; same for `eks`. They are now a single
tree under `modules/`, consumed by Terragrunt units. Modules carry no
`backend.tf` and no `aws` provider block - Terragrunt generates both, which is
what makes one copy reusable across accounts and regions.

**Terragrunt is the only deployment path.** Units declare dependencies
explicitly, so `terragrunt run --all apply` walks vpc → eks → karpenter in
order, and each layer gets its own state file.

**State backend.** S3 with native locking (`use_lockfile`) instead of a
DynamoDB lock table, SSE-KMS with a customer-managed key, versioning, and a
lifecycle rule for non-current versions. One less resource to bootstrap and no
lock-table drift.

## ☸️ EKS

| Before | After | Why |
|---|---|---|
| module v19.16.0 | v21.25.x | v19 predates access entries and Pod Identity |
| Kubernetes 1.30 / 1.31 | 1.36 | both were in extended support, which the sandbox blocks on cost |
| `aws-auth` ConfigMap + `manage_aws_auth_configmap` | access entries, `authentication_mode = "API"` | the module dropped ConfigMap management in v20; access entries do not require reaching the Kubernetes API to repair access |
| IRSA for the EBS CSI driver | EKS Pod Identity | no OIDC trust policy to maintain |
| hand-written allow-all security group rules | `node_security_group_enable_recommended_rules` | the custom rules included a duplicate `egress_all` key and blanket `-1` allows that were never needed |
| separate spot node group | removed | the sandbox will not support EC2 Spot at all |
| `t3a.medium` only | `["t3.medium", "t3a.medium"]` | a single instance type is a single point of capacity failure |
| AL2 | AL2023 | AL2 is end-of-life for EKS |
| no IMDS hardening | IMDSv2 required, hop limit 1 | blocks container-to-node-role credential theft |
| - | `node_repair_config` | EKS replaces unhealthy nodes without operator involvement |
| AWS default `upgradePolicy` (`EXTENDED`) | `STANDARD` | the default parks a cluster on an end-of-life version at premium pricing instead of upgrading it - see [auto-upgrade](../auto-upgrade/) |
| AMI pinned at node group creation | `use_latest_ami_release_version` | a managed node group never patches itself otherwise |

The old configuration also referenced `var.cluster_version` and
`var.eks_cluster_name`, neither of which was ever declared - `terraform
validate` failed on the committed code.

## ⚡ Autoscaling

**Cluster Autoscaler is gone.** It scaled ASGs that had to be declared per
instance shape in advance, and the blueprint ran it alongside a disabled
Karpenter - two autoscalers configured, neither doing the job.

**Karpenter v1alpha5 → v1.** `Provisioner` and `AWSNodeTemplate` became
`NodePool` and `EC2NodeClass`. The old manifests also carried a hardcoded
instance profile id (`eks-d2c36c9e-...`), which is unportable by construction,
and `ttlSecondsAfterEmpty` / `ttlSecondsUntilExpired`, replaced by
`consolidationPolicy` / `consolidateAfter` and `expireAfter`.

The discovery tag key changed too: `karpenter.sh/discovery/<cluster>` in
v1alpha5, `karpenter.sh/discovery` in v1. Carrying the old key forward is the
most common reason a v1 NodePool provisions nothing.

## 🔐 Security

Findings that came out of this pass, listed for the record:

- `terraform/hashicorp-vault/tls/vault.key` is a committed private TLS key
- `terraform/argocd/argocd` is a committed SSH private key
- the old `README.md` published a real account id and node role ARNs

Rotate the two keys and purge them from history. Removing them in a new commit
leaves them fully readable in every prior commit.
