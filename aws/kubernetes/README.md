# ☸️ Kubernetes add-ons

Helm-installed components that sit on top of the Terragrunt-managed cluster.
Each directory pins a single `CHART_VERSION`, installs CRDs explicitly before
the chart, and ships a working end-to-end test.

### Controllers

| Directory | Component | Chart | Fronted by |
|---|---|---|---|
| 🎛️ [aws-load-balancer-controller/](aws-load-balancer-controller/) | AWS Load Balancer Controller v3.5.0 | `eks/aws-load-balancer-controller` 3.5.0 | ALB per Ingress (or shared by group) |
| 🚦 [traefik/](traefik/) | Traefik Proxy v3.7.11 | `traefik/traefik` 41.3.0 | one NLB |

### Routing resources

| Directory | Kind | Routes |
|---|---|---|
| 🌐 [alb-ingress/](alb-ingress/) | `Ingress` | path-based demo behind a real ALB |
| 🧭 [traefik-ingressroute/](traefik-ingressroute/) | `IngressRoute` + `Middleware` | path-based demo, and `app.saqlainmushtaq.com` host route with security headers |

Install the AWS Load Balancer Controller **first** — Traefik's `Service` of type
`LoadBalancer` is provisioned by it.

## 🔀 Which one should a workload use?

- **`ingressClassName: alb`** — AWS-native routing, TLS from ACM, and AWS owns
  the data plane. Best when you want fewer moving parts.
- **`ingressClassName: traefik-external` or an `IngressRoute`** — when you need
  middlewares (rate limiting, auth, rewrites), dynamic configuration, or
  ingress config that moves between clouds unchanged.

Both are installed here so the choice is per workload rather than per cluster.

## ⚠️ Why the IAM is elsewhere

The AWS Load Balancer Controller needs AWS permissions, and permissions are
infrastructure. They live in the
[`alb-controller-iam`](../terragrunt/env/dev/region/us-east-1/alb-controller-iam)
Terragrunt unit and are bound to the controller's service account with EKS Pod
Identity. Install that unit before the chart.

Traefik needs no AWS permissions of its own — the load balancer it sits behind
is created for it by the controller.
