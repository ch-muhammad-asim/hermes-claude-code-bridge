# ☁️ GCP Custom VPC + GKE Deployment (gcloud CLI)

Single-subnet custom VPC + a **public, zonal, cost-optimized** GKE cluster sized to fit the Pluralsight / A Cloud Guru GCP sandbox quotas (≈8 vCPU per region). Provisioned entirely with the `gcloud` CLI.

## 🏗️ Architecture

| Component | Name | CIDR / Config | Purpose |
|-----------|------|---------------|---------|
| VPC | custom-vpc | custom subnet mode | Isolated network |
| Subnet | gke-subnet | 10.10.0.0/24 (+ auto pod/service ranges) | GKE nodes, internet-facing |
| GKE | gke-cluster | **zonal**, `e2-medium` **on-demand** ×3, 100 GB pd-standard | Kubernetes workloads (public endpoint + Workload Identity) |

### GKE Cluster Details

| Property | Value | Why |
|----------|-------|-----|
| Cluster name | `gke-cluster` | |
| Location | **Zonal** (`us-central1-a`) | Regional spreads nodes ×3 zones → busts the 8-vCPU sandbox quota |
| Machine type | `e2-medium` (2 vCPU, 4 GB) | 3 nodes × 2 vCPU = 6 vCPU, under the 8-vCPU quota |
| Node count | **3** (static pool) | Always exactly 3 nodes |
| Provisioning | **On-demand** | Reliable (no preemption); the sandbox is time-boxed (~4 h) so cost is moot |
| Boot disk | 100 GB `pd-standard` | GKE default disk type and size |
| Release channel | `regular` | Keeps auto-upgrade managed (don't disable it) |
| Workload Identity | Enabled (`GKE_METADATA`) | Lets in-cluster services auth to Google APIs without node keys |
| Master access | Public (`0.0.0.0/0`) | Sandbox convenience; lock to your IP for anything real |
| IP aliasing | Enabled | VPC-native cluster |

> **Sandbox quotas:** ≈8 vCPU/region, max 6 nodes, 2 node pools, 2 clusters. Cloud Build is also throttled (~3 invocations) — build images locally with `docker build` instead of `gcloud builds submit`.

> **What changed vs. the old config:** dropped the unused private/database subnets + Cloud Router + Cloud NAT (the cluster only ever used one subnet, and public nodes egress via their own external IPs — no NAT needed); shrank `e2-standard-4` regional ×3 (**12 vCPU, fails to create**) down to `e2-medium` zonal on-demand ×3 (**6 vCPU**); added Workload Identity.

## ✅ Prerequisites

- gcloud CLI installed and authenticated (`gcloud auth login`)
- The sandbox's **real** project ID (the pre-filled one is often stale):

```bash
gcloud projects list
gcloud config set project <YOUR_REAL_PROJECT_ID>
```

## 🚀 Deploy

### 1. Set Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"
export VPC_NAME="custom-vpc"
export SUBNET_NAME="gke-subnet"
export SUBNET_RANGE="10.10.0.0/24"
export CLUSTER_NAME="gke-cluster"
export WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"
```

### 2. Enable APIs

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  --project=$PROJECT_ID
```

### 3. Create Custom VPC + Subnet

```bash
gcloud compute networks create $VPC_NAME \
  --project=$PROJECT_ID \
  --subnet-mode=custom \
  --bgp-routing-mode=regional

gcloud compute networks subnets create $SUBNET_NAME \
  --project=$PROJECT_ID \
  --region=$REGION \
  --network=$VPC_NAME \
  --range=$SUBNET_RANGE \
  --enable-private-ip-google-access
```

### 4. Create Firewall Rules

```bash
# Allow internal communication within the VPC
gcloud compute firewall-rules create ${VPC_NAME}-allow-internal \
  --project=$PROJECT_ID \
  --network=$VPC_NAME \
  --allow=tcp,udp,icmp \
  --source-ranges=$SUBNET_RANGE \
  --priority=1000

# Allow SSH only from Google IAP (no public 0.0.0.0/0 SSH)
gcloud compute firewall-rules create ${VPC_NAME}-allow-ssh-iap \
  --project=$PROJECT_ID \
  --network=$VPC_NAME \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --priority=1000
```

> GKE auto-manages firewall rules for LoadBalancer services and health checks, so you don't need to pre-open 80/443 yourself.

### 5. Create the Cost-Optimized GKE Cluster

```bash
gcloud container clusters create $CLUSTER_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --network=$VPC_NAME \
  --subnetwork=$SUBNET_NAME \
  --release-channel=regular \
  --machine-type=e2-medium \
  --num-nodes=3 \
  --disk-type=pd-standard \
  --disk-size=100 \
  --enable-ip-alias \
  --workload-pool=$WORKLOAD_POOL \
  --workload-metadata=GKE_METADATA \
  --enable-master-authorized-networks \
  --master-authorized-networks=0.0.0.0/0
```

> **Note:** a static, on-demand 3-node pool (no autoscaling, no Spot) so you always have exactly 3 nodes with no preemption. The sandbox auto-expires (~4 h), so on-demand pricing is a non-issue.

### 6. Get Cluster Credentials

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE
```

## 🔍 Verify

```bash
gcloud compute networks list --project=$PROJECT_ID
gcloud compute networks subnets list --project=$PROJECT_ID
gcloud compute firewall-rules list --project=$PROJECT_ID
gcloud container clusters list --project=$PROJECT_ID

# Confirm Workload Identity is on
gcloud container clusters describe $CLUSTER_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --format='yaml(workloadIdentityConfig)'

kubectl get nodes
kubectl cluster-info
```

## 🔗 Connect to GKE

```bash
gcloud container clusters get-credentials $CLUSTER_NAME --project=$PROJECT_ID --zone=$ZONE
kubectl get namespaces
kubectl run test --image=nginx --rm -it -- /bin/bash
```

## 🧹 Teardown

No manual cleanup needed — the Pluralsight GCP sandbox auto-shuts down and wipes the entire project (~4 h after launch; see the "Auto Shutdown" time in the sandbox UI).

## 🔐 Hermes Agent Dashboard Credentials

**Dashboard URL:** https://hermes.saqlainmushtaq.com/login

| Key | Value |
|-----|-------|
| Username | `admin` |
| Password | Stored in K8s secret (see below) |

### View Secrets in Cluster (DO NOT commit output)

```bash
# Get dashboard password
kubectl get secret hermes-agent-secrets -n devops-agent -o jsonpath='{.data.HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH}' | base64 -d && echo

# View all secrets (internal use only)
kubectl get secret hermes-agent-secrets -n devops-agent -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['data']; \
  [print(f'{k}: {__import__(\"base64\").b64decode(v).decode()}') for k,v in d.items()]"
```

### Other Config

| Key | Value |
|-----|-------|
| Default Model | `claude-opus-4-8` |
| Default Provider | `claude-code-bridge` |
| Namespace | `devops-agent` |
| Secret Name | `hermes-agent-secrets` |

### Rotate Dashboard Password (if login fails)

**Step 1: Generate new password and hash**

```bash
# Generate random password
export NEW_PASS=$(openssl rand -hex 28)
echo "New password: $NEW_PASS"

# Hash with Hermes image (scrypt - MUST use Hermes image, not generic hasher)
export HASH=$(docker run --rm \
  --entrypoint /opt/hermes/.venv/bin/python \
  -e PYTHONPATH=/opt/hermes \
  -e P="$NEW_PASS" \
  nousresearch/hermes-agent:v2026.7.20 \
  -c 'import os;from plugins.dashboard_auth.basic import hash_password;print(hash_password(os.environ["P"]))')

echo "Hash: $HASH"
```

**Step 2: Delete and recreate the secret**

```bash
kubectl delete secret hermes-agent-secrets -n devops-agent

kubectl create secret generic hermes-agent-secrets -n devops-agent \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=CLAUDE_CODE_PROXY_API_KEY="$(openssl rand -hex 32)" \
  --from-literal=HERMES_DEFAULT_API_MODE=chat_completions \
  --from-literal=HERMES_DEFAULT_BASE_URL=http://127.0.0.1:18181/v1 \
  --from-literal=HERMES_DEFAULT_MODEL=claude-opus-4-8 \
  --from-literal=HERMES_DEFAULT_PROVIDER=claude-code-bridge
```

**Step 3: Restart the pod**

```bash
kubectl rollout restart statefulset hermes-agent -n devops-agent
```

**Step 4: Save password locally (DO NOT commit)**

```bash
mkdir -p $HOME/hermes-creds
cat > $HOME/hermes-creds/hermes-dashboard-${PROJECT_ID}.txt << EOF
PROJECT_ID=${PROJECT_ID}
HERMES_DASHBOARD_URL=https://hermes.saqlainmushtaq.com
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${NEW_PASS}
EOF
chmod 600 $HOME/hermes-creds/hermes-dashboard-${PROJECT_ID}.txt
```

> **Warning:** Never use `openssl dgst`, `python hashlib`, or any generic hasher. Hermes uses **scrypt** internally — only the Hermes image produces valid hashes.

## 📌 Project

- **Project ID:** your-gcp-project-id
- **Region/Zone:** us-central1 / us-central1-a
