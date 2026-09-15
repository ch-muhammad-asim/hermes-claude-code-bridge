# 📁 terraform/

Kubernetes manifests and helper configuration that are applied with `kubectl`
or `helm`, not by Terraform. The infrastructure modules moved to `modules/` and
are deployed through Terragrunt - see the root [README](../README.md).

| Directory | Contents |
|---|---|
| `alb-ingress/` | AWS Load Balancer Controller policy and sample Ingress resources |
| `argocd/` | ArgoCD Helm values |
| `developer/` | RBAC for the read-only developer role |
| `ebs/` | gp3 StorageClass example |
| `hashicorp-vault/` | Vault on EKS values, TLS and KMS auto-unseal notes |
| `karpenter/` | **Deprecated** v1alpha5 manifests - see `karpenter/DEPRECATED.md` |
