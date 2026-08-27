# 🚦 Traefik v3 Ingress (EKS)

Installs **Traefik v3** as an ingress controller on Amazon EKS, fronted by a
**Network Load Balancer**. Tuned for AWS via [`eks-values.yaml`](./eks-values.yaml).

| Component | Version |
|-----------|---------|
| Helm chart | `traefik/traefik` **v41.3.0** |
| Traefik Proxy | v3.7.11 |

> 📌 Check the newest chart with `helm search repo traefik/traefik --versions` and bump `CHART_VERSION` below.

---

## 🧭 Traefik or the AWS Load Balancer Controller?

Both are installed in this blueprint, and they are not redundant:

| | AWS Load Balancer Controller | Traefik |
|---|---|---|
| Data plane | ALB / NLB, managed by AWS | pods you run |
| Routing model | `Ingress` + annotations | `IngressRoute` CRD, middlewares, priorities |
| TLS | ACM certificates on the ALB | cert-manager, or ACM on the NLB |
| Per-request middleware | ❌ | ✅ rate limit, auth, rewrite, circuit breaker |
| Cost | per ALB-hour + LCU | one NLB, plus the pods |
| Portability | AWS only | same config on any cluster |

A useful split: **ALB** for coarse, AWS-native routing where you want AWS to own
the data plane; **Traefik** where you need middleware, dynamic configuration, or
config that moves between clouds unchanged.

Traefik sits behind an **NLB, not an ALB** — Traefik already does L7 routing and
TLS, so an ALB in front would be a second, redundant L7 hop you pay for.

---

## 🔢 One version, pinned everywhere

Everything is driven by a **single `CHART_VERSION`** so the CRDs, the chart and
the values never drift apart:

```bash
export CHART_VERSION=41.3.0          # single source of truth

helm repo add traefik https://traefik.github.io/charts
helm repo update
```

---

## 📦 Step 1 — Install the CRDs (pinned to the chart version)

Helm **does not** create or update CRDs on `upgrade` (see
[HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)), so
CRDs are installed explicitly — and pinned to the **same** chart version with
`--version "$CHART_VERSION"`. Always apply CRDs **before** installing or
upgrading the chart.

```bash
helm show crds traefik/traefik --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
```

- `helm show crds … --version "$CHART_VERSION"` renders exactly the CRDs shipped with that chart release — no floating `latest`.
- `--server-side` avoids the client-side annotation size limit; `--force-conflicts` lets this manager own the fields.

Verify (Traefik v3 ships 25 CRDs):

```bash
kubectl get crd | grep -E 'traefik\.io|hub\.traefik\.io' | wc -l   # → 25
```

> 🧩 **Gateway API?** Its CRDs are no longer bundled (since chart v40.2.0). Only if you use the Kubernetes Gateway API provider:
> ```bash
> kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
> ```

---

## 🚀 Step 2 — Install Traefik (same pinned version)

```bash
helm -n traefik upgrade --install traefik traefik/traefik --version "$CHART_VERSION" --create-namespace --values eks-values.yaml --wait --timeout 6m
```

The NLB takes a few minutes to become active after the Service is created.

---

## 🔍 Verification

### Helm-level

```bash
helm -n traefik list
```

```bash
helm -n traefik status traefik
```

```bash
helm -n traefik history traefik
```

```bash
helm -n traefik get values traefik --all
```

```bash
helm -n traefik get manifest traefik | head -40
```

```bash
helm -n traefik get notes traefik
```

Render locally without touching the cluster:

```bash
helm template traefik traefik/traefik --version "$CHART_VERSION" --values eks-values.yaml | head -60
```

Diff your values against the chart defaults — this is how the schema changes
between major chart versions get caught:

```bash
helm show values traefik/traefik --version "$CHART_VERSION" > /tmp/traefik-defaults.yaml
```

```bash
diff /tmp/traefik-defaults.yaml eks-values.yaml | head -40
```

```bash
helm show chart traefik/traefik --version "$CHART_VERSION"
```

Dry-run an upgrade:

```bash
helm -n traefik upgrade traefik traefik/traefik --version "$CHART_VERSION" --values eks-values.yaml --dry-run --debug | head -40
```

### Cluster-level

```bash
kubectl -n traefik get pods -o wide
```

```bash
kubectl -n traefik get svc traefik
```

```bash
kubectl get ingressclass
```

```bash
kubectl -n traefik logs -l app.kubernetes.io/name=traefik --tail=50
```

Check Traefik's own health endpoint from inside the cluster:

```bash
kubectl -n traefik exec deploy/traefik -- wget -qO- http://localhost:9000/ping
```

---

## ✅ End-to-end test

[`../traefik-ingressroute/demo-ingressroute.yaml`](../traefik-ingressroute/demo-ingressroute.yaml) deploys
`whoami` behind an `IngressRoute` with a response-header `Middleware`, which
proves the CRD provider is doing more than plain routing.

```bash
kubectl apply -f ../traefik-ingressroute/demo-ingressroute.yaml
```

```bash
export NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```bash
echo "$NLB"
```

```bash
curl -si "http://$NLB/whoami" | head -12
```

A correct response is `HTTP/1.1 200 OK` **and** the `X-Served-By: traefik-eks`
header injected by the middleware.

Inspect the routers and services Traefik actually built:

```bash
kubectl -n traefik get ingressroute,middleware -A
```

```bash
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'traefik')].TargetGroupArn" --output text | head -1) --output table
```

**Recorded result, 2026-08-27:** NLB
`k8s-traefik-traefik-4aa5761898-029280f894ef86fb.elb.us-east-1.amazonaws.com`
returned **HTTP 200** with `X-Served-By: traefik-eks`; both target groups
`healthy` in IP mode.

Tear the test down:

```bash
kubectl delete -f ../traefik-ingressroute/demo-ingressroute.yaml
```

---

## ⚠️ The trap that costs an hour

`eks-values.yaml` sets `providers.kubernetesCRD.ingressClass: traefik-external`.
That makes Traefik **ignore every `IngressRoute` that does not carry a matching
class annotation**:

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik-external
```

Without it you get healthy NLB targets, a running Traefik, and a flat **404** —
because the route was silently dropped before a router was ever built. This was
hit during the verification run above.

Confirm what Traefik actually loaded before blaming the load balancer:

```bash
kubectl -n traefik logs -l app.kubernetes.io/name=traefik --tail=100 | grep -i 'ingressroute\|router'
```

---

## 💡 Notes worth keeping

**The health check is on port 9000.** `/ping` lives on the `traefik` entrypoint,
which is deliberately not exposed publicly. The NLB annotations point the health
check at it; the traffic ports are 8000/8443 behind exposed 80/443.

**Two replicas, on the system node group.** Traefik is the entrance to the data
plane. Pinning it away from Karpenter capacity means a consolidation event can
never drain the whole ingress path at once.

**Chart v41 moved the entrypoint TLS switch.** It is `ports.websecure.http.tls`,
not `ports.websecure.tls`; the values schema rejects the old placement outright.
Similarly, top-level `ping:` was removed. Always `diff` against
`helm show values` after a major chart bump.

---

## 🧹 Uninstall

```bash
helm -n traefik uninstall traefik
```

```bash
kubectl delete namespace traefik
```

CRDs survive `helm uninstall` by design:

```bash
kubectl get crd | grep -E 'traefik\.io|hub\.traefik\.io' | awk '{print $1}' | xargs kubectl delete crd
```

---

## 📚 References

| Topic | Link |
|---|---|
| Traefik Kubernetes CRD provider | https://doc.traefik.io/traefik/providers/kubernetes-crd/ |
| IngressRoute reference | https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/ |
| Middlewares | https://doc.traefik.io/traefik/middlewares/overview/ |
| Helm chart source | https://github.com/traefik/traefik-helm-chart |
| Helm CRD policy (HIP-0011) | https://github.com/helm/community/blob/main/hips/hip-0011.md |
| NLB annotations (AWS LB Controller) | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/ |
| GKE variant of this setup | https://github.com/ch-muhammad-asim/hermes-claude-code-bridge/tree/main/kubernetes/traefik |
