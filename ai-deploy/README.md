# 🤖 ai-deploy — one-shot Hermes Agent deployment

**Point your agent at this file and say: _"deploy hermes agent"._** This is the end-to-end
runbook that stands up the whole stack by orchestrating the other folders — GCP network, GKE,
Traefik ingress, and the Hermes Agent itself — then hands you working dashboard credentials.

It's written so a capable coding agent (Claude Code / Hermes) *or* a human can execute it top to
bottom. Every command is inline (no wrapper scripts to trust), idempotent where practical, and
cross-links to the deep-dive docs.

```
 ai-deploy  ──▶  ../gcp (VPC + GKE)  ──▶  ../kubernetes/traefik (ingress)  ──▶  ../kubernetes (Hermes)
                                                                                      │
                                                                    dashboard @ hermes.saqlainmushtaq.com
```

---

## 🧰 What you need

- `gcloud`, `kubectl`, `helm`, `curl`, `openssl`, `jq`, and a container engine — **Docker or OrbStack**
- A Google Cloud project you can create resources in
- DNS control for `hermes.saqlainmushtaq.com` (to point it at the Traefik IP)

**Tool check (OS-aware).** On macOS (Apple Silicon) Homebrew installs most of these under
`/opt/homebrew/bin`, while **Docker/OrbStack** put `docker` under `/usr/local/bin`; on Linux they're
typically in `/usr/local/bin` or `/usr/bin`. This confirms each is on `PATH` and prints where it
resolved (use the printed absolute path if your agent runs in a minimal-`PATH` shell):

```bash
case "$(uname -s)" in
  Darwin) echo "🍎 macOS — Homebrew: /opt/homebrew/bin (gcloud/kubectl/helm) · Docker/OrbStack: /usr/local/bin/docker" ;;
  Linux)  echo "🐧 Linux — usually /usr/local/bin or /usr/bin" ;;
esac
for t in gcloud kubectl helm docker curl openssl jq; do
  p="$(command -v "$t" 2>/dev/null)" && echo "✓ $t → $p" || echo "🛑 missing: $t — install it before continuing"
done
```

Set the shared variables once — every step below reuses them:

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"
export NAMESPACE="devops-agent"
export HERMES_DOMAIN="hermes.saqlainmushtaq.com"
export HERMES_IMAGE="nousresearch/hermes-agent:v2026.7.20"
# Where generated dashboard credentials are written. Override to a secure, private
# location (e.g. export HERMES_CREDS_DIR="$HOME/secure/hermes"); defaults to /tmp.
export HERMES_CREDS_DIR="${HERMES_CREDS_DIR:-/tmp/hermes-creds}"
```

---

## 1️⃣ Preflight: GCP authentication + required APIs

> 🛑 **The one human gate.** The AI runs everything unattended **except** this: if there is no
> valid gcloud credential, it must **stop and ask the user to authenticate** — never guess an
> account, never proceed unauthenticated. Every step after this uses the account confirmed here.

**a) Verify a valid authenticated account exists.** Checks, in order: is gcloud initialized
(`~/.config/gcloud`), is there an **ACTIVE** account, and is its token actually **valid** (not
expired/revoked). If any check fails, stop and have the user run the printed commands:

```bash
if [ ! -d "$HOME/.config/gcloud" ]; then
  echo "🛑 gcloud is not initialized (no ~/.config/gcloud)."
  echo "   Ask the user to run:  gcloud auth login  &&  gcloud auth application-default login"
  return 2>/dev/null || exit 1
fi

export GCLOUD_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"
if [ -z "$GCLOUD_ACCOUNT" ] || ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "🛑 No valid, authenticated gcloud account (missing, expired, or revoked)."
  echo "   Ask the user to run:"
  echo "     gcloud auth login"
  echo "     gcloud auth application-default login   # ADC, for Workload Identity checks"
  return 2>/dev/null || exit 1
fi
echo "✅ Authenticated as: $GCLOUD_ACCOUNT"
```

**b) Pin that account and project for every subsequent command:**

```bash
gcloud config set account "$GCLOUD_ACCOUNT"
gcloud config set project "$PROJECT_ID"
# Confirm the account can actually see the project (catches wrong-account / no-access early):
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null \
  || { echo "🛑 $GCLOUD_ACCOUNT cannot access project $PROJECT_ID — check the account/project."; return 2>/dev/null || exit 1; }
```

**c) Enable required APIs — check which are already on, enable only the missing ones, then
proceed** (don't blindly re-enable):

```bash
REQUIRED_APIS="container.googleapis.com compute.googleapis.com iamcredentials.googleapis.com \
iam.googleapis.com cloudresourcemanager.googleapis.com"
ENABLED="$(gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)')"
for api in $REQUIRED_APIS; do
  if printf '%s\n' "$ENABLED" | grep -qx "$api"; then
    echo "✓ $api (already enabled)"
  else
    echo "… enabling $api"
    gcloud services enable "$api" --project="$PROJECT_ID"
  fi
done
echo "✅ Required APIs are enabled"
```

> 🔎 The **optional** GCP-MCP observability APIs (`logging`, `monitoring`, `cloudtrace`) are only
> needed if you do step 5 — enable them there, the same check-then-enable way.

## 2️⃣ GCP: create the custom VPC

**Create the custom VPC + subnet + firewall** (full details: [`../gcp`](../gcp)):

```bash
export VPC_NAME="custom-vpc" SUBNET_NAME="gke-subnet" SUBNET_RANGE="10.10.0.0/24"

gcloud compute networks create "$VPC_NAME" --project="$PROJECT_ID" --subnet-mode=custom --bgp-routing-mode=regional
gcloud compute networks subnets create "$SUBNET_NAME" --project="$PROJECT_ID" --region="$REGION" \
  --network="$VPC_NAME" --range="$SUBNET_RANGE" --enable-private-ip-google-access
gcloud compute firewall-rules create "${VPC_NAME}-allow-internal" --project="$PROJECT_ID" \
  --network="$VPC_NAME" --allow=tcp,udp,icmp --source-ranges="$SUBNET_RANGE"
gcloud compute firewall-rules create "${VPC_NAME}-allow-ssh-iap" --project="$PROJECT_ID" \
  --network="$VPC_NAME" --allow=tcp:22 --source-ranges=35.235.240.0/20
```

## 3️⃣ GKE: create the cluster

Cost-optimized, Workload-Identity-enabled (needed for the recommended GCP MCP auth in step 5):

```bash
export CLUSTER_NAME="gke-cluster"
gcloud container clusters create "$CLUSTER_NAME" --project="$PROJECT_ID" --zone="$ZONE" \
  --network="$VPC_NAME" --subnetwork="$SUBNET_NAME" --release-channel=regular \
  --machine-type=e2-medium --num-nodes=3 \
  --disk-type=pd-standard --disk-size=100 --enable-ip-alias \
  --workload-pool="${PROJECT_ID}.svc.id.goog" --workload-metadata=GKE_METADATA \
  --enable-master-authorized-networks --master-authorized-networks=0.0.0.0/0

gcloud container clusters get-credentials "$CLUSTER_NAME" --project="$PROJECT_ID" --zone="$ZONE"
kubectl get nodes
```

## 4️⃣ Traefik ingress + dependencies

Install Traefik v3 with **CRDs pinned to the chart version** (full details: [`../kubernetes/traefik`](../kubernetes/traefik)):

```bash
export CHART_VERSION=41.0.2
helm repo add traefik https://traefik.github.io/charts && helm repo update
# CRDs first, pinned to the chart version (Helm never auto-updates CRDs)
helm show crds traefik/traefik --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" \
  --create-namespace --values ../kubernetes/traefik/gke-values.yaml --wait
kubectl get pods -n traefik
```

## 5️⃣ (Optional, educational) MCP setup — makes Hermes *powerful* 💪

**Not required to deploy.** Hermes runs fine without any MCP. But wiring the **read-only MCP**
integrations is what turns it into a real Lead-SRE investigator:

- 🐙 **GitHub MCP** — read repos, PRs, Actions, checks.
- 🔎 **GCP observability MCP** — Cloud Logging, Monitoring, Trace (recommended auth: **Workload
  Identity**, keyless — see [`../kubernetes`](../kubernetes) → "GCP MCP authentication").
- ☸️ **kubectl** — read-only `get/describe/logs/top`.

All are **read-only by design** (RBAC + tool policy). Skip this section for a minimal deploy; add
it later without redeploying. See [`../kubernetes`](../kubernetes) for the full setup.

> ✅ **Minimal deploy just works.** The `hermes-agent-github-app` and `hermes-agent-google-oauth`
> Secrets are marked **`optional: true`** in the StatefulSet, so the pod starts **without** them —
> only `hermes-agent-secrets` (step 6) is required. Create the MCP Secrets later to light up GitHub
> / GCP MCP; no redeploy needed. (Skipping them will **not** leave the pod stuck `Pending` on a
> missing Secret.)

## 6️⃣ Deploy Hermes + generate dashboard credentials

> 🐳 **A container engine must be running** (Docker **or** OrbStack — both provide the `docker`
> CLI + socket) — the dashboard password is hashed with **scrypt**, which only the Hermes image
> produces correctly. Verify first:
>
> ```bash
> docker info >/dev/null 2>&1 || { echo "🛑 No running container engine — start Docker Desktop or OrbStack"; }
> ```

**a) Namespace:**

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

**b) Generate the admin password, hash it with the Hermes image, and create the Secret:**

```bash
export NEW_PASS="$(openssl rand -hex 24)"
export HASH="$(docker run --rm --entrypoint /opt/hermes/.venv/bin/python \
  -e PYTHONPATH=/opt/hermes -e P="$NEW_PASS" "$HERMES_IMAGE" \
  -c 'import os;from plugins.dashboard_auth.basic import hash_password;print(hash_password(os.environ["P"]))')"

kubectl create secret generic hermes-agent-secrets -n "$NAMESPACE" \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="$HASH" \
  --from-literal=HERMES_DASHBOARD_BASIC_AUTH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=CLAUDE_CODE_PROXY_API_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**c) Store the credentials so you can log in.** Written to `HERMES_CREDS_DIR` (default `/tmp`) and
also exported as env vars for the current shell:

```bash
mkdir -p "$HERMES_CREDS_DIR" && chmod 700 "$HERMES_CREDS_DIR"
cat > "$HERMES_CREDS_DIR/hermes-dashboard.txt" <<EOF
HERMES_DASHBOARD_URL=https://${HERMES_DOMAIN}/login
HERMES_DASHBOARD_USERNAME=admin
HERMES_DASHBOARD_PASSWORD=${NEW_PASS}
EOF
chmod 600 "$HERMES_CREDS_DIR/hermes-dashboard.txt"

export HERMES_DASHBOARD_USERNAME=admin
export HERMES_DASHBOARD_PASSWORD="$NEW_PASS"
echo "🔑 Dashboard login saved to $HERMES_CREDS_DIR/hermes-dashboard.txt (and \$HERMES_DASHBOARD_PASSWORD)"
```

> 🔒 **Never commit these.** `HERMES_CREDS_DIR` defaults to `/tmp`; point it at a private, secure
> directory for real use (`export HERMES_CREDS_DIR=…`). The plaintext password is **never** stored
> in the cluster — only its scrypt hash is.

**d) Apply the Hermes manifests** (the single-source `hermes-params` in the kustomization already
carries `GCP_PROJECT_ID`/`HERMES_DOMAIN`):

```bash
kubectl apply -k ../kubernetes
kubectl rollout status statefulset/hermes-agent -n "$NAMESPACE" --timeout=300s
```

## 7️⃣ DNS: point the domain at the Traefik external IP 🌐

Get the LoadBalancer IP Traefik was assigned, then create/update an **A record** for
`hermes.saqlainmushtaq.com`:

```bash
export TRAEFIK_IP="$(kubectl get svc -n traefik traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "➡️  Create DNS A record:  ${HERMES_DOMAIN}  →  ${TRAEFIK_IP}"
```

Update the record at your DNS provider (Cloudflare/registrar). Propagation + TLS issuance take a
few minutes.

## 8️⃣ Health check ✅

```bash
# In-cluster (works before DNS/TLS): pods Ready?
kubectl get pods -n "$NAMESPACE"
kubectl rollout status statefulset/hermes-agent -n "$NAMESPACE"

# Bridge + gateway health via port-forward (pre-DNS):
kubectl -n "$NAMESPACE" port-forward statefulset/hermes-agent 8642:8642 >/tmp/pf.log 2>&1 &
sleep 3; curl -fsS http://127.0.0.1:8642/health && echo " ✅ gateway healthy"; kill %1 2>/dev/null

# Public (after DNS + TLS): dashboard reachable?
curl -fsS "https://${HERMES_DOMAIN}/health" && echo " ✅ public health OK"
```

Then open **`https://hermes.saqlainmushtaq.com/login`** and sign in with `admin` / the password in
`$HERMES_CREDS_DIR/hermes-dashboard.txt`. 🎉

---

## 🔁 Teardown

```bash
kubectl delete -k ../kubernetes --ignore-not-found
helm -n traefik uninstall traefik
gcloud container clusters delete "$CLUSTER_NAME" --project="$PROJECT_ID" --zone="$ZONE" --quiet
# VPC/subnet/firewall cleanup: see ../gcp
```

> 📚 Deep dives: [`../gcp`](../gcp) (network + GKE) · [`../kubernetes`](../kubernetes) (Hermes,
> RBAC, MCP auth) · [`../kubernetes/traefik`](../kubernetes/traefik) (ingress).
