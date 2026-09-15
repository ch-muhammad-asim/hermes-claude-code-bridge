# 🧭 Traefik IngressRoute

Routing resources for **Traefik v3** — `IngressRoute` and `Middleware` CRDs,
served through the single NLB that fronts Traefik.

> 📌 Requires Traefik. Install it first: [`../traefik/`](../traefik/)

| File | What it creates |
|---|---|
| [`demo-ingressroute.yaml`](demo-ingressroute.yaml) | path-based route — `whoami` on `PathPrefix(/whoami)` with a response-header middleware |
| [`app-ingressroute.yaml`](app-ingressroute.yaml) | host-based route — `app.saqlainmushtaq.com` with a security-headers middleware, and a commented TLS variant |

---

## 🧩 Why IngressRoute instead of Ingress?

Traefik reads plain `Ingress` objects too, but its routing model does not fit in
them. `IngressRoute` gives you what annotations cannot express:

| | `Ingress` | `IngressRoute` |
|---|---|---|
| Match expression | host + path only | `Host()`, `PathPrefix()`, `Headers()`, `Query()`, and boolean combinations |
| Middleware chain | annotation strings | typed `Middleware` objects, ordered per route |
| Route priority | implicit | explicit `priority` |
| Multiple services per route | ❌ | ✅ with weights, for canaries |
| TLS options per route | ❌ | ✅ `tls.options` |

---

## 🚀 Deploy

Path-based demo:

```bash
kubectl apply -f demo-ingressroute.yaml
```

Host-based application route:

```bash
kubectl apply -f app-ingressroute.yaml
```

---

## ☁️ Behind Cloudflare (proxied)

If the record is **proxied** (orange cloud), Cloudflare terminates TLS at the
edge and opens a **second** connection to the origin. Which port it uses is
decided by the zone's SSL/TLS mode:

| Cloudflare SSL mode | Connects to origin on | Needs a route on |
|---|---|---|
| Flexible | HTTP :80 | `web` |
| **Full** (default) | HTTPS :443, certificate **not** validated | `websecure` + any cert |
| Full (strict) | HTTPS :443, certificate **validated** | `websecure` + a trusted cert |

> ⚠️ **The failure this causes.** In **Full** mode an IngressRoute that only
> lists `entryPoints: [web]` returns a bare **`404 page not found`** in the
> browser - while `curl` against port 80 returns a perfect 200. Cloudflare is
> hitting 443, where no router exists. Nothing in the 404 hints at the cause.
>
> [`app-ingressroute.yaml`](app-ingressroute.yaml) therefore serves **both**
> entrypoints and carries an empty `tls: {}` block, which terminates TLS with
> Traefik's built-in self-signed certificate. Full mode accepts it because it
> does not validate the origin certificate.

For **Full (strict)**, issue a Cloudflare Origin CA certificate
(SSL/TLS → Origin Server → Create Certificate) and reference it:

```bash
kubectl -n app-demo create secret tls app-tls --cert=origin.pem --key=origin-key.pem
```

```yaml
  tls:
    secretName: app-tls
```

Diagnose the origin directly, bypassing Cloudflare entirely - test **both**
ports, because that is what separates this failure from a routing mistake:

```bash
export NLB_IP=$(dig +short "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" | head -1)
```

```bash
curl -s -o /dev/null -w 'http  %{http_code}
' --resolve "app.saqlainmushtaq.com:80:$NLB_IP" "http://app.saqlainmushtaq.com/"
```

```bash
curl -sk -o /dev/null -w 'https %{http_code}
' --resolve "app.saqlainmushtaq.com:443:$NLB_IP" "https://app.saqlainmushtaq.com/"
```

`http 200` with `https 404` is this exact problem.

Cloudflare adds headers you can use to confirm the request really came through
the edge - `Cf-Ray`, `Cf-Connecting-Ip`, `Cf-Visitor` and `X-Forwarded-Proto`.

## 🌐 DNS

Point the hostname at Traefik's NLB with a **CNAME** — never an A record, since
the NLB's addresses change:

```bash
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

```
app.saqlainmushtaq.com.  CNAME  k8s-traefik-traefik-xxxxxxxxxx.elb.us-east-1.amazonaws.com.
```

For a Route 53 hosted zone, prefer an **alias A record** to the NLB — it
resolves at the zone apex and costs nothing per query.

---

## 🔍 Verification

Before DNS exists, test with `--resolve` so curl sends the right `Host` header
to the load balancer's actual address:

```bash
export NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```bash
export NLB_IP=$(dig +short "$NLB" | head -1)
```

```bash
curl -si --resolve "app.saqlainmushtaq.com:80:$NLB_IP" "http://app.saqlainmushtaq.com/" | head -14
```

Path-based demo:

```bash
curl -si "http://$NLB/whoami" | head -12
```

What Traefik actually loaded:

```bash
kubectl get ingressroute,middleware -A
```

```bash
kubectl -n app-demo describe ingressroute app
```

```bash
kubectl -n traefik logs -l app.kubernetes.io/name=traefik --tail=100 | grep -iE 'router|ingressroute|error'
```

Load balancer health:

```bash
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'traefik')].TargetGroupArn" --output text | head -1) --output table
```

---

## ✅ Recorded result

Verified 2026-08-27 on `cloudgeeks-eks-dev`, through NLB
`k8s-traefik-traefik-4aa5761898-029280f894ef86fb.elb.us-east-1.amazonaws.com`:

```
HTTP/1.1 200 OK
Referrer-Policy: strict-origin-when-cross-origin
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-Served-By: traefik-eks
X-Xss-Protection: 1; mode=block

Hostname: app-5d4784c9c7-gdvgp
```

Both NLB addresses returned 200 and traffic landed on both replicas, so the
route, the middleware chain and cross-AZ balancing all work.

Then through Cloudflare (proxied CNAME, SSL mode **Full**) at
`https://app.saqlainmushtaq.com` — after adding the `websecure` entrypoint:

```
Hostname: app-5d4784c9c7-gdvgp
X-Forwarded-Proto: https
X-Forwarded-Port: 443
X-Forwarded-Server: traefik-5dfb9b6487-s9b96
Cf-Visitor: {"scheme":"https"}
Cf-Ray: a3191ade68777d50-SIN
```

Before that change the same URL returned `404 page not found` while port 80
answered 200 — see the Cloudflare section above.

---

## ⚠️ The trap that costs an hour

`../traefik/eks-values.yaml` sets `providers.kubernetesCRD.ingressClass:
traefik-external`. Traefik then **ignores every `IngressRoute` without a
matching class annotation**:

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik-external
```

Symptom: healthy NLB targets, Traefik running, and a flat **404** — because the
route was dropped before a router was ever built. Both files here carry the
annotation.

---

## 🔐 Adding TLS

`app-ingressroute.yaml` ships a commented `websecure` variant. Create the
certificate Secret, then uncomment it:

```bash
kubectl -n app-demo create secret tls app-tls --cert=fullchain.pem --key=privkey.pem
```

With cert-manager, issue a `Certificate` into the same namespace and reference
its `secretName` under `tls.secretName`. TLS terminates at **Traefik**, not at
the NLB — the NLB stays a layer-4 passthrough, which is the point of putting
Traefik behind an NLB rather than an ALB.

---

## 💡 Patterns worth knowing

**Canary by weight** — two services on one route:

```yaml
services:
  - name: app
    port: 80
    weight: 90
  - name: app-canary
    port: 80
    weight: 10
```

**Rate limiting** is a Middleware, not an annotation:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ratelimit
spec:
  rateLimit:
    average: 100
    burst: 50
```

**Middlewares are namespaced.** Referencing one from another namespace needs
`namespace-name@kubernetescrd` syntax, and a route that references a missing
middleware fails closed — the whole route stops serving.

---

## 🧹 Clean up

```bash
kubectl delete -f app-ingressroute.yaml
```

```bash
kubectl delete -f demo-ingressroute.yaml
```

---

## 📚 References

| Topic | Link |
|---|---|
| IngressRoute reference | https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/ |
| Routing rules and matchers | https://doc.traefik.io/traefik/routing/routers/ |
| Middlewares overview | https://doc.traefik.io/traefik/middlewares/overview/ |
| Kubernetes CRD provider | https://doc.traefik.io/traefik/providers/kubernetes-crd/ |
| cert-manager | https://cert-manager.io/docs/ |
