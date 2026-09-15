# ⚠️ Deprecated - Karpenter v1alpha5

These manifests target the `karpenter.sh/v1alpha5` `Provisioner` and
`karpenter.k8s.aws/v1alpha1` `AWSNodeTemplate` APIs, which Karpenter removed in
v1.0. They will not apply to any currently supported Karpenter release.

They are kept only as a reference for anyone migrating an old cluster.

The supported path is the `karpenter` Terragrunt unit, which manages the v1
`NodePool` and `EC2NodeClass` resources:

- module: [`modules/karpenter`](../../modules/karpenter)
- unit: `terragrunt/env/dev/region/us-east-1/karpenter`
- guide: [`docs/karpenter/`](../../docs/karpenter/)

## 🔄 What changed

| v1alpha5 | v1 |
|---|---|
| `Provisioner` | `NodePool` |
| `AWSNodeTemplate` | `EC2NodeClass` |
| `ttlSecondsAfterEmpty` | `disruption.consolidateAfter` |
| `ttlSecondsUntilExpired` | `template.spec.expireAfter` |
| `consolidation.enabled` | `disruption.consolidationPolicy` |
| `subnetSelector` / `securityGroupSelector` | `subnetSelectorTerms` / `securityGroupSelectorTerms` |
| `instanceProfile` (hardcoded id) | `role` (Karpenter manages the profile) |
| tag `karpenter.sh/discovery/<cluster>` | tag `karpenter.sh/discovery` |

The apps under `app/` still work - retarget their tolerations and node
selectors at the labels the v1 NodePool applies.
