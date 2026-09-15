# 🚦 Traefik v3 Ingress (GKE)

Installs **Traefik v3** as the ingress controller that terminates TLS and routes traffic to the Hermes Agent dashboard/API `IngressRoute` (see [`../workloads/ingressroute.yaml`](../workloads/ingressroute.yaml), host `hermes.saqlainmushtaq.com`). Tuned for **GCP GKE** via [`gke-values.yaml`](./gke-values.yaml).

| Component | Version |
|-----------|---------|
| Helm chart | `traefik/traefik` **v41.0.2** |
| Traefik Proxy | v3.7.x |

> 📌 Check the newest chart with `helm search repo traefik/traefik --versions` and bump `CHART_VERSION` below.

---

## 🔢 One version, pinned everywhere

Everything is driven by a **single `CHART_VERSION`** so the CRDs, the chart, and the values never drift apart:

```bash
export CHART_VERSION=41.0.2          # single source of truth

helm repo add traefik https://traefik.github.io/charts
helm repo update
```

---

## 📦 Step 1 — Install the CRDs (pinned to the chart version)

Helm **does not** create or update CRDs on `upgrade` (see [HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)), so CRDs are installed explicitly — and pinned to the **same** chart version with `--version "$CHART_VERSION"`. Always apply CRDs **before** installing/upgrading the chart.

```bash
helm show crds traefik/traefik --version "$CHART_VERSION" \
  | kubectl apply --server-side --force-conflicts -f -
```

- `helm show crds … --version "$CHART_VERSION"` renders exactly the CRDs shipped with that chart release — no floating `latest`.
- `--server-side` avoids the client-side annotation size limit; `--force-conflicts` lets this manager own the fields.

Verify (Traefik v3 ships 25 CRDs):

```bash
kubectl get crd | grep -E 'traefik\.io|hub\.traefik\.io' | wc -l   # → 25
```

> 🧩 **Gateway API?** Its CRDs are no longer bundled (since chart v40.2.0). Only if you use the Kubernetes Gateway API provider:
> ```bash
> kubectl apply --server-side --force-conflicts \
>   -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
> ```

---

## 🚀 Step 2 — Install Traefik (same pinned version)

```bash
helm -n traefik upgrade --install traefik traefik/traefik \
  --version "$CHART_VERSION" \
  --create-namespace \
  --values gke-values.yaml \
  --wait
```

---

## ✅ Verify

```bash
kubectl get pods -n traefik
kubectl get svc  -n traefik                              # note the LoadBalancer EXTERNAL-IP for DNS
kubectl get ingressclass
kubectl get ingressroute -n devops-agent                # the Hermes dashboard route
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50
```

Point your DNS (`hermes.saqlainmushtaq.com`) at the LoadBalancer external IP, then browse to the dashboard.

---

## ⬆️ Upgrades

Bump `CHART_VERSION`, then **CRDs first, chart second** (the order matters):

```bash
export CHART_VERSION=<new-version>
helm repo update
helm show crds traefik/traefik --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" --values gke-values.yaml --wait
```

---

## 🌐 GCP IP ranges (optional trusted IPs)

To trust Google Front End / LB source ranges in `forwardedHeaders`, generate the list and paste it under `ports.websecure.forwardedHeaders.trustedIPs` in `gke-values.yaml`:

```bash
curl -s https://www.gstatic.com/ipranges/cloud.json \
  | jq -r '.prefixes[] | [.ipv4Prefix, .ipv6Prefix] | .[] | select(.)'
```

---

## ⚠️ Breaking changes to know (chart v41)

If upgrading from an older chart, note:

1. **Logs:** `logs.general` → `log`, `logs.access` → `accessLog`.
2. **File provider:** `providers.file.content` is now an object (`{}`), not a string.
3. **Access-log filters:** `statuscodes` → `statusCodes`, `retryattempts` → `retryAttempts`, `minduration` → `minDuration`.
4. **Image defaults:** `registry`/`repository` now default to `null`.

📖 See the [chart changelog](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/Changelog.md) and the [v2→v3 migration guide](https://doc.traefik.io/traefik/v3.0/migration/v2-to-v3/).
