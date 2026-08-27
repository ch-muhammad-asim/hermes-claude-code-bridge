# 🤖 Hermes Agent Deployments

Cloud-provider-native deployments of the **Hermes Lead SRE Agent**, one directory per
model backend. Each is a self-contained Kustomize root — no shared base to keep in
sync, no cross-directory overlays.

| Directory | Backend | Model | Ingress |
| --- | --- | --- | --- |
| [`aws-bedrock/`](aws-bedrock/) | Amazon Bedrock — EKS + Pod Identity, or k3s + instance profile | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | `hermes.saqlainmushtaq.com` |

## 🧭 Relationship to the rest of the repo

```text
hermes-agent/aws-bedrock/   Hermes on Bedrock, on EKS      <- this tree
vertex-ai/                  Hermes on Vertex AI, on GKE    <- the configuration this is ported from
kubernetes/                 Hermes via the Claude Code CLI bridge, on GKE
aws/                        The EKS blueprint (Terragrunt) this deployment runs on
```

> ⚠️ The Pluralsight **AI** Cloud Sandbox denies `eks:CreateCluster` via an AWS
> Organizations SCP, so `aws-bedrock/` ships both cluster paths: the EKS base and a
> single-node k3s substitute. The bridge is byte-identical on both — boto3's default
> credential chain resolves Pod Identity on EKS and IMDS on EC2. Details in
> [`aws-bedrock/README.md`](aws-bedrock/README.md).

`aws-bedrock/` is a faithful port of `vertex-ai/`: identical Hermes runtime config,
identical hardening posture, identical chat-completions ⇄ Anthropic Messages
translation. What differs is transport (boto3 `InvokeModel` + SigV4 instead of a
Google `AuthorizedSession`), identity (EKS Pod Identity instead of GKE Workload
Identity), storage (`gp3` instead of `standard-rwo`), and one capability the port
adds: **scoped write access so the agent can actually fix a broken pod**.

Start with [`aws-bedrock/README.md`](aws-bedrock/README.md).
