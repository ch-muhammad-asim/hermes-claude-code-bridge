#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  gcp-infra.sh — provision the custom VPC + cost-optimized GKE cluster from
#  this directory's README, in one command.
#
#    ./gcp-infra.sh                          # use the active gcloud project
#    ./gcp-infra.sh --project my-project     # target a specific project
#    ./gcp-infra.sh --dry-run                # print every command, change nothing
#    ./gcp-infra.sh --help
#
#  Idempotent: every step checks for the resource first, so a re-run after a
#  partial failure (or an interrupted sandbox) continues instead of erroring out.
#
#  Sized for the Pluralsight / A Cloud Guru GCP sandbox (~8 vCPU per region):
#  a ZONAL cluster with 3 × e2-medium on-demand nodes = 6 vCPU. A regional
#  cluster would place 3 nodes per zone (12 vCPU) and fail to create.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults (override with flags or by exporting first) ─────────────────────
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VPC_NAME="${VPC_NAME:-custom-vpc}"
SUBNET_NAME="${SUBNET_NAME:-gke-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/24}"
CLUSTER_NAME="${CLUSTER_NAME:-gke-cluster}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
NUM_NODES="${NUM_NODES:-3}"
DISK_TYPE="${DISK_TYPE:-pd-standard}"
DISK_SIZE="${DISK_SIZE:-100}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-regular}"
# Sandbox convenience. Lock this to your own IP/CIDR for anything real.
MASTER_AUTHORIZED_NETWORKS="${MASTER_AUTHORIZED_NETWORKS:-0.0.0.0/0}"
DRY_RUN=0

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --project <id>       GCP project (default: active gcloud project)
  --region <region>    Default: $REGION
  --zone <zone>        Default: $ZONE  (zonal on purpose — see the note above)
  --cluster <name>     Default: $CLUSTER_NAME
  --vpc <name>         Default: $VPC_NAME
  --subnet <name>      Default: $SUBNET_NAME
  --subnet-range <cidr>Default: $SUBNET_RANGE
  --machine-type <mt>  Default: $MACHINE_TYPE
  --num-nodes <n>      Default: $NUM_NODES
  --master-networks <cidr[,cidr]>
                       Authorized networks for the control plane.
                       Default: $MASTER_AUTHORIZED_NETWORKS (sandbox convenience)
  --dry-run            Print the gcloud commands without running them
  -h, --help           This help

Teardown: the Pluralsight/ACG sandbox auto-wipes the whole project (~4h), so no
cleanup is normally needed. Outside a sandbox, delete in reverse order:
  gcloud container clusters delete <cluster> --zone <zone>
  gcloud compute firewall-rules delete <vpc>-allow-internal <vpc>-allow-ssh-iap
  gcloud compute networks subnets delete <subnet> --region <region>
  gcloud compute networks delete <vpc>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT_ID="${2:?--project needs a value}"; shift 2 ;;
    --region)         REGION="${2:?}"; shift 2 ;;
    --zone)           ZONE="${2:?}"; shift 2 ;;
    --cluster)        CLUSTER_NAME="${2:?}"; shift 2 ;;
    --vpc)            VPC_NAME="${2:?}"; shift 2 ;;
    --subnet)         SUBNET_NAME="${2:?}"; shift 2 ;;
    --subnet-range)   SUBNET_RANGE="${2:?}"; shift 2 ;;
    --machine-type)   MACHINE_TYPE="${2:?}"; shift 2 ;;
    --num-nodes)      NUM_NODES="${2:?}"; shift 2 ;;
    --master-networks) MASTER_AUTHORIZED_NETWORKS="${2:?}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 64 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
skip()  { printf '  \033[0;33m↷ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[0;32m✔ %s\033[0m\n' "$*"; }
die()   { printf '\033[0;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# Run a command, or just print it under --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  \033[0;90m$ %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

# ── Prerequisites ───────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v gcloud >/dev/null 2>&1 || die "gcloud not found. Install the Google Cloud CLI first."
info "gcloud: $(command -v gcloud)"

if [ "$DRY_RUN" -eq 0 ]; then
  gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
    || die "No active gcloud account. Run: gcloud auth login"
  info "account: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
fi

# The sandbox's pre-filled project is often stale, so resolve it explicitly.
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  [ "$PROJECT_ID" = "(unset)" ] && PROJECT_ID=""
fi
[ -n "$PROJECT_ID" ] || die "No project. Pass --project <id>, or: gcloud config set project <id>
Tip: list the real sandbox project with 'gcloud projects list'."

WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"

cat <<EOF

  project        : $PROJECT_ID
  region / zone  : $REGION / $ZONE   (zonal: ${NUM_NODES} × ${MACHINE_TYPE})
  vpc / subnet   : $VPC_NAME / $SUBNET_NAME ($SUBNET_RANGE)
  cluster        : $CLUSTER_NAME
  workload pool  : $WORKLOAD_POOL
  master access  : $MASTER_AUTHORIZED_NETWORKS
EOF
[ "$DRY_RUN" -eq 1 ] && info "(dry run — nothing will be created)"

# vCPU sanity check against the sandbox quota.
case "$MACHINE_TYPE" in
  e2-medium|e2-small|e2-micro) vcpu_each=2 ;;
  *) vcpu_each=0 ;;
esac
if [ "$vcpu_each" -gt 0 ]; then
  total=$(( vcpu_each * NUM_NODES ))
  [ "$total" -gt 8 ] && info "⚠️  ${NUM_NODES} × ${MACHINE_TYPE} ≈ ${total} vCPU — above the ~8 vCPU sandbox quota; creation may fail."
fi

# ── 1. Enable APIs ──────────────────────────────────────────────────────────
step "1/6  Enabling required APIs"
run gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  --project="$PROJECT_ID"
ok "container, compute, iamcredentials"

# ── 2. Custom VPC ───────────────────────────────────────────────────────────
step "2/6  Custom VPC: $VPC_NAME"
if [ "$DRY_RUN" -eq 0 ] && gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  skip "VPC $VPC_NAME already exists"
else
  run gcloud compute networks create "$VPC_NAME" \
    --project="$PROJECT_ID" \
    --subnet-mode=custom \
    --bgp-routing-mode=regional
  ok "VPC created (custom subnet mode)"
fi

# ── 3. Subnet ───────────────────────────────────────────────────────────────
step "3/6  Subnet: $SUBNET_NAME ($SUBNET_RANGE)"
if [ "$DRY_RUN" -eq 0 ] && gcloud compute networks subnets describe "$SUBNET_NAME" \
     --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  skip "subnet $SUBNET_NAME already exists in $REGION"
else
  # Private Google Access lets nodes reach Google APIs without external routing.
  run gcloud compute networks subnets create "$SUBNET_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network="$VPC_NAME" \
    --range="$SUBNET_RANGE" \
    --enable-private-ip-google-access
  ok "subnet created with Private Google Access"
fi

# ── 4. Firewall rules ───────────────────────────────────────────────────────
# GKE auto-manages rules for LoadBalancer services and health checks, so only
# internal traffic and IAP-scoped SSH are opened here — never 0.0.0.0/0 on :22.
step "4/6  Firewall rules"
fw_internal="${VPC_NAME}-allow-internal"
if [ "$DRY_RUN" -eq 0 ] && gcloud compute firewall-rules describe "$fw_internal" --project="$PROJECT_ID" >/dev/null 2>&1; then
  skip "$fw_internal already exists"
else
  run gcloud compute firewall-rules create "$fw_internal" \
    --project="$PROJECT_ID" \
    --network="$VPC_NAME" \
    --allow=tcp,udp,icmp \
    --source-ranges="$SUBNET_RANGE" \
    --priority=1000
  ok "$fw_internal (intra-VPC tcp/udp/icmp)"
fi

fw_ssh="${VPC_NAME}-allow-ssh-iap"
if [ "$DRY_RUN" -eq 0 ] && gcloud compute firewall-rules describe "$fw_ssh" --project="$PROJECT_ID" >/dev/null 2>&1; then
  skip "$fw_ssh already exists"
else
  # 35.235.240.0/20 is Google's IAP TCP-forwarding range — SSH is not public.
  run gcloud compute firewall-rules create "$fw_ssh" \
    --project="$PROJECT_ID" \
    --network="$VPC_NAME" \
    --allow=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --priority=1000
  ok "$fw_ssh (SSH from Google IAP only)"
fi

# ── 5. GKE cluster ──────────────────────────────────────────────────────────
step "5/6  GKE cluster: $CLUSTER_NAME (this takes ~5-10 min)"
if [ "$DRY_RUN" -eq 0 ] && gcloud container clusters describe "$CLUSTER_NAME" \
     --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  skip "cluster $CLUSTER_NAME already exists in $ZONE"
else
  # Static on-demand pool: no autoscaling, no Spot — exactly $NUM_NODES nodes,
  # no preemption. Workload Identity (GKE_METADATA) lets in-cluster service
  # accounts authenticate to Google APIs with no node keys.
  run gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --network="$VPC_NAME" \
    --subnetwork="$SUBNET_NAME" \
    --release-channel="$RELEASE_CHANNEL" \
    --machine-type="$MACHINE_TYPE" \
    --num-nodes="$NUM_NODES" \
    --disk-type="$DISK_TYPE" \
    --disk-size="$DISK_SIZE" \
    --enable-ip-alias \
    --workload-pool="$WORKLOAD_POOL" \
    --workload-metadata=GKE_METADATA \
    --enable-master-authorized-networks \
    --master-authorized-networks="$MASTER_AUTHORIZED_NETWORKS"
  ok "cluster created"
fi

# ── 6. Credentials ──────────────────────────────────────────────────────────
step "6/6  Fetching kubectl credentials"
run gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE"
ok "kubeconfig context updated"

# ── Verify ──────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  step "Dry run complete — nothing was created"
  exit 0
fi

step "Verifying"
gcloud container clusters list --project="$PROJECT_ID" \
  --filter="name=$CLUSTER_NAME" \
  --format='table(name,location,currentMasterVersion,currentNodeCount,status)' 2>/dev/null || true

wi="$(gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
      --format='value(workloadIdentityConfig.workloadPool)' 2>/dev/null || true)"
if [ -n "$wi" ]; then ok "Workload Identity: $wi"; else info "⚠️  Workload Identity not reported — check the cluster describe output."; fi

if command -v kubectl >/dev/null 2>&1; then
  kubectl get nodes -o wide 2>/dev/null || info "kubectl could not reach the cluster yet; retry in a moment."
else
  info "kubectl not installed — skipping node check."
fi

cat <<EOF

$(printf '\033[0;32m✔ Infrastructure ready\033[0m')

  Context : $(kubectl config current-context 2>/dev/null || echo '<kubectl not configured>')
  Nodes   : ${NUM_NODES} × ${MACHINE_TYPE} in $ZONE

Next:
  • Traefik ingress (chart-pinned CRDs) : ../kubernetes/traefik/
  • Hermes + Claude Code bridge         : kubectl apply -k ../kubernetes
  • Hermes + OmniRoute                  : cd ../omniroute/kubernetes && ./generate-secrets.sh && kubectl apply -k .

Note: build container images locally with 'docker build' — the sandbox throttles
Cloud Build after ~3 invocations.
EOF
