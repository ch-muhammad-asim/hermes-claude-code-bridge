# 🔥 Karpenter load testing

An end-to-end proof that Karpenter provisions nodes under real load and takes
them away again afterwards.

The point of this suite is that nothing is faked. Replica counts are not set by
hand - CPU load drives the HPA, the HPA creates pods that do not fit, and
Karpenter is left to work out what hardware to buy.

```
  load generator          HPA                    Karpenter
       │                   │                         │
       ├─ POST /ConsumeCPU │                         │
       │   pods burn CPU   │                         │
       │                   ├─ CPU > 50% target       │
       │                   ├─ adds pods              │
       │                   │   pods go Pending ──────┤
       │                   │                         ├─ launches nodes
       │                   │                         │
       └─ job ends         ├─ scales in (5m window)  │
                           │                         └─ consolidates nodes away
```

## 📦 What is here

| File | Purpose |
|---|---|
| `manifests/00-namespace.yaml` | Namespace with restricted Pod Security Standard and a ResourceQuota |
| `manifests/10-app.yaml` | `cpu-burner` Deployment, Service and PodDisruptionBudget |
| `manifests/20-hpa.yaml` | HorizontalPodAutoscaler, CPU target 50% |
| `manifests/30-loadgen.yaml` | Job that drives the load |
| `manifests/kustomization.yaml` | Applies the first three together |

The workload is `registry.k8s.io/e2e-test-images/resource-consumer`, the image
Kubernetes' own HPA end-to-end tests use. It exposes an endpoint that burns a
**requested** number of millicores for a **requested** number of seconds, so the
load is deterministic rather than "hammer a web server and hope".

## ⚠️ Read this before running it

The binding sandbox limit is **instance count - nine EC2 instances
account-wide**, not vCPU. That is easy to trip, because Karpenter bin-packs
onto the cheapest shape that fits, which here is `t3a.small`: 2 vCPU, of which
roughly 1.3 is schedulable once daemonsets are placed. Each node therefore
holds about 5 pods at a 250m request.

The defaults are sized so the whole account stays at six instances or fewer:

| Control | Value | Effect |
|---|---|---|
| HPA `maxReplicas` | 6 | ~1.5 CPU of requests |
| NodePool `limits.cpu` | 8 | Karpenter hard-stops at 4 nodes |
| System node group | 2 | fixed |
| **Worst case total** | **6 instances** | 3 below the sandbox cap |

Raising `maxReplicas` without recomputing this is how you trip the cap and get
the sandbox reclaimed. The NodePool's `limits.cpu` is the backstop that holds
even if the HPA is misconfigured - it is not optional.

## 🚀 Running the test

Deploy the app and its autoscaler:

```bash
kubectl apply -k load-testing/manifests
```

Wait for the app to be ready - the first pods will themselves trigger a
Karpenter node, because they carry `nodeSelector: provisioned-by=karpenter`:

```bash
kubectl wait --for=condition=available --timeout=300s deployment/cpu-burner -n load-testing
```

Start the load:

```bash
kubectl apply -f load-testing/manifests/30-loadgen.yaml
```

Watch all three layers react, in three terminals:

```bash
kubectl get hpa -n load-testing -w
```

```bash
kubectl get nodeclaims -w
```

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

Keep an eye on the instance count while it runs:

```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" --query "length(Reservations[].Instances[])"
```

## 🧹 Cleaning up

The Job stops on its own after 240 seconds and the cluster scales itself back
down. To stop immediately:

```bash
kubectl delete namespace load-testing
```

Deleting the namespace removes the load, the pods and the reason for the nodes
to exist; Karpenter reclaims them within a couple of minutes. Confirm:

```bash
kubectl get nodes -L karpenter.sh/nodepool
```

## ✅ Recorded results

Run of 2026-08-27 on `cloudgeeks-eks-dev`, Kubernetes 1.36, Karpenter 1.14.1.

**Scale-up**

| Event | Time | State |
|---|---|---|
| 🟢 Load generator started | 09:51:10 | 2 pods, 4 nodes |
| 📈 HPA at ceiling, CPU 131% of a 50% target | 09:51:47 (**37s**) | 6 pods |
| ⚡ Karpenter nodes serving the load | 09:51:47 | 5 nodes / 5 EC2 instances |

**Scale-down**

| Event | Time | State |
|---|---|---|
| 🟢 Load phase ended | 09:55:22 | 6 pods |
| 📉 HPA scaled in after its 5-minute stabilisation window | 10:02:25 (**~7m**) | 2 pods, CPU 0% |
| 🧹 Karpenter consolidated the surplus nodes | within ~2m of the pods going | back to the system node group |

Scale-down is deliberately far slower than scale-up: a 5-minute HPA
stabilisation window, then Karpenter's `consolidateAfter`. Reacting to a lull as
fast as you react to a spike just produces node churn, and churn costs more than
the idle capacity saves.

An earlier run with `maxReplicas: 20` reached **7 instances** - within the
NodePool's ceiling, but far too close to the sandbox's nine. That is what the
current limits exist to prevent, and why the arithmetic above is written down.

## 🔍 Troubleshooting

**Pods stay `Pending` and no node appears.** Check the NodePool has not hit its
limit, and that the pending pod's requests can actually be satisfied by an
allowed instance size:

```bash
kubectl get nodepool default -o jsonpath='{.status}{"\n"}'
```

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

**HPA shows `<unknown>` for CPU.** metrics-server has not scraped yet, or is not
installed. It ships as an EKS add-on in this blueprint:

```bash
kubectl top pods -n load-testing
```

**Pods `CrashLoopBackOff` with permission errors.** The namespace enforces the
restricted Pod Security Standard. A container that needs to write outside its
image, or bind a privileged port, will not start - that is the policy working,
not a bug.

## 📚 Related

- [`docs/karpenter/`](../docs/karpenter/) - NodePool settings and production tuning
- [`docs/sandbox/`](../docs/sandbox/) - the sandbox limits this test is bounded by
- [`docs/testing/`](../docs/testing/) - full blueprint validation results
