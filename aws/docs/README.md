# 📚 Documentation

Each guide lives in its own directory, so browsing to it on GitHub renders the
page directly.

| Guide | What it covers |
|---|---|
| 🧪 [sandbox/](sandbox/) | Pluralsight AWS sandbox limits and how the code enforces them at plan time |
| 🪣 [bootstrap/](bootstrap/) | Creating the state bucket and KMS key before the first Terragrunt run |
| ⚡ [karpenter/](karpenter/) | NodePool and EC2NodeClass settings, why each is set that way, production tuning |
| ⬆️ [auto-upgrade/](auto-upgrade/) | What EKS auto-upgrades and what it does not, versus GKE - plus upgrade caveats |
| 💾 [backup-dr/](backup-dr/) | Native AWS Backup for EKS, Velero alongside it, and restore drills |
| 🔄 [migration/](migration/) | What changed from the previous revision of this blueprint and why |
| ✅ [testing/](testing/) | Validation procedure and recorded results from the live cluster |

Related, outside this directory:

| | |
|---|---|
| 🔥 [../load-testing/](../load-testing/) | HPA + Karpenter load test, commands and measured timings |
| 📁 [../terraform/](../terraform/) | Kubernetes manifests applied with kubectl or helm |
