# 🚦 Traefik v3 — ingress for Hermes

TLS ingress controller for this deployment's single public route,
**`hermes.saqlainmushtaq.com`**. OmniRoute is deliberately *not* routed — see
[Why OmniRoute is not exposed](#-why-omniroute-is-not-exposed).

| | Value |
|---|---|
| Chart | `traefik/traefik` **41.0.2** (latest) |
| Traefik | **v3.7.6** |
| IngressClass | `traefik-external` (not the cluster default) |
| Entry points | `web` :80 → 301 → `websecure` :443 |
| Service | `LoadBalancer`, GKE **External** + NEG |
| Dashboard | API on, chart IngressRoute **off** (port-forward only) |

> ♻️ **Already installed Traefik from [`../../../kubernetes/traefik/`](../../../kubernetes/traefik)?**
> Then you're done — the values here are identical, the same controller watches the same
> `traefik-external` class, and it will pick up the Hermes route automatically. Skip to
> [Deploy the route](#-4-deploy-the-route). Installing twice in one cluster gives you two
> LoadBalancers fighting over the same IngressClass.

## ✅ Prerequisites

- A GKE cluster and `kubectl` context — provision with [`../../../gcp/gcp-infra.sh`](../../../gcp/gcp-infra.sh)
- `helm` 3.x
- A DNS A record you can point at the LoadBalancer IP (set in step 5)

```bash
helm version --short
kubectl config current-context
```

## 📦 1. Add the chart repo

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik

# Confirm the newest chart + the Traefik version it ships
helm search repo traefik/traefik --versions | head -5
#   NAME             CHART VERSION   APP VERSION
#   traefik/traefik  41.0.2          v3.7.6
```

Everything below is driven by **one** `CHART_VERSION` so the CRDs, the chart and the values can
never drift apart:

```bash
export CHART_VERSION=41.0.2          # single source of truth
export TRAEFIK_NS=traefik
```

## 🧩 2. Install the CRDs (pinned to the chart version)

Helm **does not** create or update CRDs on `helm upgrade` ([HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)),
so they're installed explicitly — and pinned to the **same** version as the chart. Always CRDs
**before** the chart.

```bash
helm show crds traefik/traefik --version "$CHART_VERSION" \
  | kubectl apply --server-side --force-conflicts -f -

# Verify: IngressRoute, Middleware, TLSOption, … all traefik.io
kubectl get crd | grep traefik.io
```

- `helm show crds … --version "$CHART_VERSION"` renders exactly the CRDs shipped with that
  release — no floating `latest`.
- `--server-side --force-conflicts` avoids the *"metadata.annotations: Too long"* failure that
  client-side apply hits on large CRDs.

## 🚀 3. Install the chart

```bash
kubectl create namespace "$TRAEFIK_NS" --dry-run=client -o yaml | kubectl apply -f -

helm -n "$TRAEFIK_NS" upgrade --install traefik traefik/traefik \
  --version "$CHART_VERSION" \
  --values gke-values.yaml \
  --wait

# Rollout + the external IP the LoadBalancer got
kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik --timeout=300s
kubectl -n "$TRAEFIK_NS" get svc traefik -o wide
```

Grab the IP for DNS:

```bash
export LB_IP="$(kubectl -n "$TRAEFIK_NS" get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "LoadBalancer IP: $LB_IP"
```

> ⏳ The IP can take 1–3 minutes to appear while GCP provisions the LB. An empty value just
> means "not ready yet" — re-run the command.

## 🌐 4. Deploy the route

```bash
cd ..                       # omniroute/kubernetes
kubectl apply -k .
kubectl -n omniroute get ingressroute
```

The route is [`../workloads/hermes-ingressroute.yaml`](../workloads/hermes-ingressroute.yaml):

| Match | → Service | Why |
|---|---|---|
| ``Host(`hermes.saqlainmushtaq.com`) && PathPrefix(`/v1`)`` | `hermes:8642` | Hermes' OpenAI-compatible API |
| ``Host(`hermes.saqlainmushtaq.com`) && PathPrefix(`/health`)`` | `hermes:8642` | health probe |
| ``Host(`hermes.saqlainmushtaq.com`)`` | `hermes:9119` | dashboard (catch-all, matched last) |

`ingressClassName: traefik-external` is set **in `spec`**, not as a
`kubernetes.io/ingress.class` annotation — an annotation naming a class no controller watches is
silently ignored and the route never goes live.

## 🗺️ 5. Point DNS at the LoadBalancer

Create an **A record** for `hermes.saqlainmushtaq.com` → `$LB_IP`, then:

```bash
dig +short hermes.saqlainmushtaq.com          # should return $LB_IP
curl -sS -o /dev/null -w '%{http_code}\n' https://hermes.saqlainmushtaq.com/health   # 200
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://hermes.saqlainmushtaq.com/
#   301 -> https://hermes.saqlainmushtaq.com/     (web → websecure redirect)
```

TLS: `tls: {}` in the IngressRoute means Traefik serves its **built-in self-signed** certificate,
so browsers warn. For a trusted cert either terminate TLS at Cloudflare (proxied A record) or add
cert-manager and reference a `secretName` in the route's `tls:` block.

## 🔒 Why OmniRoute is not exposed

OmniRoute has **no IngressRoute** on purpose. It's the model gateway holding every provider
credential, and its `/v1` proxy would let anyone who reaches it spend your provider quota. Keeping
it ClusterIP-only means it is not internet-reachable **regardless** of the `REQUIRE_API_KEY`
setting — the network is the guarantee, not app config.

Reach its dashboard on demand:

```bash
kubectl -n omniroute port-forward svc/omniroute 20128:20128
# then open http://localhost:20128  (log in with INITIAL_PASSWORD)
```

Hermes still reaches it in-cluster over `http://omniroute:20128/v1` — that path never leaves the
cluster. For defense-in-depth you can also restrict which pods may connect:

```bash
kubectl -n omniroute apply -f ../optional/networkpolicy.yaml
```

## 🔧 Notable values (`gke-values.yaml`)

| Setting | Value | Why |
|---|---|---|
| `ingressClass.name` | `traefik-external` | Explicit class; `isDefaultClass: false` so it never captures unrelated Ingresses |
| `ingressClass.isDefaultClass` | `false` | Routes must opt in |
| `ingressRoute.dashboard.enabled` | `false` | No public Traefik dashboard route; use `port-forward` |
| `api.insecure` | `false` | Dashboard API is not served unauthenticated |
| `ports.web.http.redirections` | → `websecure`, permanent | All plain HTTP 301s to HTTPS |
| `ports.websecure.forwardedHeaders.trustedIPs` | Cloudflare ranges | Real client IP in logs when proxied through Cloudflare |
| `service.annotations` | `networking.gke.io/load-balancer-type: External`, `cloud.google.com/neg` | GKE external LB with container-native routing |
| `providers.kubernetesCRD/Ingress.ingressClass` | `traefik-external` | Only watches this class |
| `metrics.prometheus` | on, entry point `metrics` :9100 | Scrapeable; port not exposed publicly |
| `additionalArguments` | `--ping` | Liveness endpoint for the chart's probes |

Behind Cloudflare, regenerate the trusted ranges into `ports.websecure.forwardedHeaders.trustedIPs`:

```bash
{ curl -s https://www.cloudflare.com/ips-v4; curl -s https://www.cloudflare.com/ips-v6; } \
  | sed 's/^/        - /'
```

## ⬆️ Upgrades

Bump `CHART_VERSION`, then **CRDs first, chart second** — the order matters:

```bash
export CHART_VERSION=<new-version>
helm search repo traefik/traefik --versions | head -5     # confirm it exists

helm show crds traefik/traefik --version "$CHART_VERSION" \
  | kubectl apply --server-side --force-conflicts -f -
helm -n "$TRAEFIK_NS" upgrade --install traefik traefik/traefik \
  --version "$CHART_VERSION" --values gke-values.yaml --wait

helm -n "$TRAEFIK_NS" history traefik
kubectl -n "$TRAEFIK_NS" get pod -l app.kubernetes.io/name=traefik
```

Also update the `Chart:` comment at the top of `gke-values.yaml` so the file and the pin agree.

Rollback (CRDs are backwards-compatible within a major, so only the release is rolled):

```bash
helm -n "$TRAEFIK_NS" rollback traefik
```

## 🩺 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no matches for kind "IngressRoute"` | CRDs not installed. Run step 2 **before** applying routes. |
| `metadata.annotations: Too long` applying CRDs | Client-side apply. Use `kubectl apply --server-side --force-conflicts`. |
| Route returns 404 from Traefik | Class mismatch. The route needs `ingressClassName: traefik-external`; confirm with `kubectl -n omniroute get ingressroute hermes -o yaml`. |
| LoadBalancer IP stays `<pending>` | GCP still provisioning (1–3 min), or the cluster lacks quota for another forwarding rule. |
| Browser TLS warning | Expected — `tls: {}` uses Traefik's self-signed cert. Terminate at Cloudflare or add cert-manager. |
| `curl https://…` works, browser doesn't | DNS not propagated yet; compare `dig +short hermes.saqlainmushtaq.com` with `$LB_IP`. |
| 404 on `/v1` but the dashboard loads | The `/v1` rule must be listed **before** the catch-all host rule (it already is in the shipped file). |
| Two LoadBalancers / flapping routes | Traefik installed twice. Keep one install per cluster — see the note at the top. |

## 🧹 Teardown

```bash
helm -n "$TRAEFIK_NS" uninstall traefik
kubectl delete namespace "$TRAEFIK_NS"

# CRDs are cluster-scoped and are NOT removed by uninstall.
# Only delete them if nothing else in the cluster uses Traefik — this deletes every
# IngressRoute/Middleware object along with them.
kubectl get crd -o name | grep traefik.io | xargs -r kubectl delete
```
