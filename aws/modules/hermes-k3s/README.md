# ☸️ `hermes-k3s` — single-node Kubernetes on EC2, bootstrapped end to end

Provisions a t3.medium running **k3s**, then installs **Traefik** and the **Hermes
agent** on it. `terragrunt apply` returns a *working stack* — not just a machine.

```text
terragrunt apply --working-dir hermes-k3s
   └─ EC2 (AL2023, IMDSv2, instance profile: Bedrock invoke only)
        └─ k3s          (servicelb kept, packaged Traefik v2 disabled)
        └─ Traefik v3   (pinned chart + matching CRDs, traefik-external)
        └─ Hermes       (Secrets generated on-node, Kustomize overlay applied)
        └─ reports COMPLETE  ──▶ Terraform stops waiting and the apply succeeds
```

## ❓ Why this exists instead of `modules/eks`

Pluralsight sandboxes deny `eks:CreateCluster` through an AWS Organizations SCP
(`p-2nwbuy01`) — an org-level explicit deny that a member account cannot override.
`ec2:RunInstances` at `t3.medium` **is** permitted. Everything above the cluster
layer is identical either way, and the Hermes bridge is byte-identical: boto3's
default credential chain resolves EKS Pod Identity on EKS and the **EC2 instance
profile** here, so no application code changes.

Use `modules/eks` in any account whose SCP permits it.

---

## 🔐 How to get the cluster from EC2 onto your laptop

The node publishes its own kubeconfig, so there is **no SSH key and no inbound
port 22**. Three things have to be true for off-host `kubectl` to work, and this
module handles all three:

| Requirement | Why | Handled by |
|---|---|---|
| The API cert must list the public IP | k3s only signs `127.0.0.1` + cluster IPs, so a remote kubectl fails with *"certificate is valid for 10.43.0.1, 127.0.0.1, not `<ip>`"* | `--tls-san <public-ip>` at install |
| The kubeconfig must point at the public IP | k3s writes `https://127.0.0.1:6443`, which is useless off-host | `sed` rewrite before upload |
| Port 6443 must be reachable from you | Otherwise the connection just hangs | `api_allowed_cidrs` security-group rule |

### 1. Fetch it

```bash
terragrunt output -raw kubeconfig_fetch_command
```

That prints the exact command; it is simply:

```bash
aws s3 cp s3://<state-bucket>/k3s/kubeconfig $HOME/.kube/hermes-k3s --region us-east-1
```

```bash
chmod 600 $HOME/.kube/hermes-k3s && export KUBECONFIG=$HOME/.kube/hermes-k3s
```

```bash
kubectl get nodes -o wide
```

Keep it out of `~/.kube/config` — a separate file per cluster means `kubectl` can
never target the wrong one by accident. To use it alongside your other contexts:

```bash
export KUBECONFIG=$HOME/.kube/config:$HOME/.kube/hermes-k3s && kubectl config get-contexts
```

The context is named `default`; rename it so it is unmistakable:

```bash
kubectl config rename-context default hermes-k3s
```

### 2. Open the firewall to yourself

`api_allowed_cidrs` defaults to **empty**, which creates no rule at all — it fails
closed (no kubectl) rather than open (a world-reachable API server). Your egress IP
changes with your network, so re-apply when it does:

```bash
curl -s https://checkip.amazonaws.com
```

Set that `/32` in the unit's `api_allowed_cidrs` and re-apply. The security group
updates in place — the instance is **not** replaced.

### 3. Other ways in

| Method | When to use | Notes |
|---|---|---|
| **S3 (default)** | Always | No key material, no open SSH port. The bucket is private, KMS-encrypted, TLS-only |
| **SSM Session Manager** | Debugging the node itself | `aws ssm start-session --target <instance-id>` — no inbound port, no key. Then `sudo cat /etc/rancher/k3s/k3s.yaml` |
| **SSH + scp** | Only if you attached a key pair | Needs an inbound 22 rule this module does not create. Deliberately not the default |

Reading it straight off the node:

```bash
aws ssm start-session --target $(terragrunt output -raw instance_id) --region us-east-1
```

```bash
sudo sed "s|127.0.0.1|$(curl -s ifconfig.me)|" /etc/rancher/k3s/k3s.yaml
```

### ⚠️ The public IP changes if the instance stops

There is no Elastic IP by design (sandboxes cap them, and they cost when unattached).
Stop/start the instance and the address changes, which invalidates **both** the
kubeconfig and the cert SAN. Rebuild rather than patch:

```bash
terragrunt apply -replace=aws_instance.node --working-dir hermes-k3s
```

Attach an EIP in `main.tf` if the address must be stable.

---

## 🚀 What "end to end" means here

EC2 reports an instance as created the moment it boots — long before k3s exists.
Without a gate, `apply` would succeed against a half-built cluster and the failure
would surface later, somewhere confusing.

So the node writes its progress to `s3://<bucket>/k3s/bootstrap-status`:

```text
RUNNING → K3S_READY → TRAEFIK_READY → SECRETS_READY → COMPLETE
```

`terraform_data.bootstrap_gate` polls that object and **fails the apply** on
`FAILED:<line>` or on timeout. An `ERR` trap in the script writes the failing line
number, so a broken bootstrap names itself instead of hanging.

### 🔑 Generated credentials

The node generates the dashboard password, the bridge API key and the scrypt
password hash **on the node**, and writes the two secrets to **SSM SecureString** —
never to a log, an S3 object, or a Terraform output, so they cannot leak through
state:

```bash
terragrunt output -raw credentials_command
```

```bash
aws ssm get-parameter --name /hermes/k3s/dashboard-password --with-decryption --region us-east-1 --query Parameter.Value --output text
```

Username is `admin`. The hash is generated with the **same image** the StatefulSet
runs (`hermes_image`) — a hash from a different build will not verify.

---

## ⚙️ Inputs worth knowing

| Variable | Default | Notes |
|---|---|---|
| `deploy_hermes` | `true` | `false` gives a bare k3s cluster and stops after publishing the kubeconfig |
| `hermes_overlay` | `aws-bedrock/overlays/k3s` | **Must match `model_id`** — the node role authorizes one model. Use `.../k3s-haiku-4-5` where Sonnet 4.5 has no Marketplace subscription |
| `model_id` | Sonnet 4.5 profile | Inference-profile id. Sonnet 4.5 is `INFERENCE_PROFILE`-only on Bedrock |
| `manifests_ref` | `main` | Pin to a tag for a reproducible rebuild |
| `api_allowed_cidrs` | `[]` | Fails closed. Set your egress `/32` |
| `traefik_chart_version` | `41.3.0` | CRDs installed from the same version, so they cannot drift |
| `hermes_image` | `nousresearch/hermes-agent:v2026.8.3` | Must equal the StatefulSet's image |
| `bootstrap_timeout_minutes` | `20` | A full bootstrap typically takes 5–8 minutes |

## 🔒 Security posture

- **No static AWS credential anywhere.** The instance profile grants
  `bedrock:InvokeModel` on one model, `s3:PutObject` on exactly two object keys,
  and `ssm:PutParameter` under one prefix. Nothing else.
- **IMDSv2 required**, with `http_put_response_hop_limit = 2`. That second value is
  mandatory, not tuning: pod traffic to IMDS traverses the host network namespace
  and decrements the hop count, so at the default of `1` every pod gets a timeout
  instead of credentials and the Hermes bridge dies with `NoCredentialsError`.
- **No inbound SSH.** 80/443 are public (that is the ingress); 6443 is restricted
  to `api_allowed_cidrs`.
- Root volume is encrypted; kubeconfig and status objects are uploaded with
  `--sse aws:kms`.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Apply fails `bootstrap FAILED on the node` | A bootstrap step errored; the status names the line | `aws ssm start-session --target <id>` → `sudo tail -100 /var/log/hermes-k3s-bootstrap.log` |
| Apply times out, status stuck at `RUNNING` | Slow image pulls, or no egress | Raise `bootstrap_timeout_minutes`; confirm the NAT/IGW path |
| Apply times out, **no** status at all | The node never reached the AWS CLI | `aws ec2 get-console-output --instance-id <id> --output text \| tail -80` |
| `kubectl` hangs | 6443 not open to you | Set `api_allowed_cidrs` to your current `/32` and re-apply |
| `x509: certificate is valid for ...` | Public IP changed after a stop/start, so it is no longer in the cert SAN | `terragrunt apply -replace=aws_instance.node` |
| `AccessDeniedException` on InvokeModel | `hermes_overlay` and `model_id` disagree | Align them and re-apply |
| Model access denied citing **AWS Marketplace** | Account-level: no subscription for that model, and `bedrock:CreateFoundationModelAgreement` is denied by SCP `p-sdxy6x4w` | Switch to a subscribed model (Haiku 4.5) in **both** places |

## 🧹 Teardown

```bash
terragrunt destroy --working-dir hermes-k3s
```

The kubeconfig, status object and SSM parameters are not Terraform-managed —
remove them separately if the bucket outlives the cluster.
