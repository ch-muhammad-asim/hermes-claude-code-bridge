# 🌐 ALB Ingress

`Ingress` resources handled by the **AWS Load Balancer Controller**, which turns
each one into a real **Application Load Balancer**.

> 📌 Requires the controller. Install it first: [`../aws-load-balancer-controller/`](../aws-load-balancer-controller/)

| File | What it creates |
|---|---|
| [`demo-ingress.yaml`](demo-ingress.yaml) | namespace, echo server, `NodePort` Service and an internet-facing ALB |

---

## 🚀 Deploy

```bash
kubectl apply -f demo-ingress.yaml
```

```bash
kubectl get ingress -n alb-demo -w
```

The `ADDRESS` column stays empty for a minute or two while AWS provisions the
load balancer. When it fills in, the ALB exists.

---

## 🔍 Verification

```bash
export ALB=$(kubectl get ingress echo -n alb-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```bash
echo "$ALB"
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"
```

```bash
curl -s "http://$ALB/" | head -c 300
```

Kubernetes side — `TargetGroupBinding` is the controller's own record of the
link between a Service and an AWS target group:

```bash
kubectl get targetgroupbindings -A
```

```bash
kubectl describe ingress echo -n alb-demo | tail -20
```

AWS side — target health is where a misconfigured Ingress actually shows up:

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].{name:LoadBalancerName,scheme:Scheme,state:State.Code,dns:DNSName}" --output table
```

```bash
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'k8s-')].TargetGroupArn" --output text | head -1) --output table
```

```bash
aws elbv2 describe-listeners --load-balancer-arn $(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].LoadBalancerArn" --output text | head -1) --output table
```

If nothing happens at all, the controller is the place to look:

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 | grep -iE 'error|denied|ingress'
```

---

## ✅ Recorded result

Verified 2026-08-27 on `cloudgeeks-eks-dev`:

```
ALB   k8s-cloudgeeksdev-145b174035-1811162643.us-east-1.elb.amazonaws.com
GET / -> HTTP 200, echo server JSON body
targets healthy, IP target mode
```

---

## 🏷️ The annotations that matter

| Annotation | Why |
|---|---|
| `alb.ingress.kubernetes.io/scheme` | `internet-facing` or `internal`. Internal needs `kubernetes.io/role/internal-elb=1` on the private subnets |
| `alb.ingress.kubernetes.io/target-type` | `ip` registers pod IPs directly - fewer hops, works with Fargate. `instance` needs a NodePort on every node |
| `alb.ingress.kubernetes.io/group.name` | **The cost lever.** Ingresses sharing a group land on one ALB instead of one each |
| `alb.ingress.kubernetes.io/listen-ports` | JSON list, e.g. `'[{"HTTP": 80}]'` or `'[{"HTTPS": 443}]'` |
| `alb.ingress.kubernetes.io/healthcheck-path` | Defaults to `/`; point it at a real health endpoint |
| `alb.ingress.kubernetes.io/certificate-arn` | ACM certificate for HTTPS. Omit and the controller tries to discover one by hostname |
| `alb.ingress.kubernetes.io/tags` | Applied to the AWS resources, not the Kubernetes object |

Adding TLS is two annotations and a listener change:

```yaml
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111122223333:certificate/xxxxxxxx
alb.ingress.kubernetes.io/ssl-redirect: '443'
```

---

## ⚠️ Traps

**One ALB per Ingress by default.** Each ALB bills per hour plus LCUs. Group
them with `group.name` unless they genuinely need separate load balancers.

**Subnet tags are how discovery works.** Public subnets need
`kubernetes.io/role/elb=1`, private ones `kubernetes.io/role/internal-elb=1`.
A missing tag surfaces as `could not discover subnets`, not as a clear error.
The [`vpc`](../../modules/vpc) module sets both.

**Delete the Ingress, not the ALB.** Deleting the load balancer in the console
just makes the controller build it again.

**`NodePort`, not `LoadBalancer`.** A `Service` of type `LoadBalancer` creates a
*second* load balancer (an NLB). With an Ingress the Service only needs to be
reachable - `NodePort` for instance mode, `ClusterIP` works for IP mode.

---

## 🧹 Clean up

```bash
kubectl delete -f demo-ingress.yaml
```

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].LoadBalancerName" --output text
```

The second command should come back empty once the controller has finished.

---

## 📚 References

| Topic | Link |
|---|---|
| Ingress annotations reference | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/ |
| Ingress specification | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/spec/ |
| IngressGroup | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/#ingressgroup |
| EKS application load balancing | https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html |
