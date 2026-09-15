# 🎛️ AWS Load Balancer Controller

Installs the **AWS Load Balancer Controller**, which turns Kubernetes `Ingress`
objects into real **Application Load Balancers** and `Service` objects of type
`LoadBalancer` into **Network Load Balancers**.

| Component | Version |
|-----------|---------|
| Helm chart | `eks/aws-load-balancer-controller` **v3.5.0** |
| Controller | v3.5.0 |
| IAM policy | pinned to controller `v3.5.0`, vendored in [`modules/alb-controller-iam/iam_policy.json`](../../modules/alb-controller-iam/iam_policy.json) |

> 📌 Check the newest chart with `helm search repo eks/aws-load-balancer-controller --versions` and bump `CHART_VERSION` below.

---

## 🔐 Step 0 — IAM comes from Terragrunt, not Helm

The controller needs AWS permissions to create load balancers. Those are
infrastructure, so they are managed by the `alb-controller-iam` unit, which
creates the IAM policy, a role, and an **EKS Pod Identity association** bound to
the `aws-load-balancer-controller` service account:

```bash
terragrunt apply --working-dir terragrunt/env/dev/region/us-east-1/alb-controller-iam
```

Verify the association exists before installing the chart — if it does not, the
controller starts and then fails every reconcile with `AccessDenied`:

```bash
aws eks list-pod-identity-associations --cluster-name cloudgeeks-eks-dev --query "associations[?serviceAccount=='aws-load-balancer-controller']"
```

> 🧩 **No IRSA annotation needed.** Pod Identity supplies credentials through the
> EKS Pod Identity Agent, so `serviceAccount.annotations` stays empty. The
> service account **name** is the binding key — change it in one place and you
> must change it in both.

---

## 🔢 One version, pinned everywhere

```bash
export CHART_VERSION=3.5.0          # single source of truth

helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

---

## 📦 Step 1 — Install the CRDs (pinned to the chart version)

Helm does **not** create or update CRDs on `upgrade` (see
[HIP-0011](https://github.com/helm/community/blob/main/hips/hip-0011.md)), so
they are applied explicitly and pinned to the same chart version. Always apply
CRDs **before** installing or upgrading the chart.

```bash
helm show crds eks/aws-load-balancer-controller --version "$CHART_VERSION" | kubectl apply --server-side --force-conflicts -f -
```

Verify (this chart ships 5 CRDs — 2 for `elbv2.k8s.aws`, 3 for the Gateway API
provider):

```bash
kubectl get crd | grep -E 'elbv2\.k8s\.aws|gateway\.k8s\.aws'
```

```bash
kubectl get crd | grep -cE 'elbv2\.k8s\.aws|gateway\.k8s\.aws'   # → 5
```

---

## 🚀 Step 2 — Install the controller (same pinned version)

`values.yaml` sets `clusterName`, `region` and `vpcId` explicitly, pins the
controller to the system node group, and creates the `alb` IngressClass.

```bash
helm -n kube-system upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version "$CHART_VERSION" --values values.yaml --wait --timeout 5m
```

---

## 🔍 Verification

### Helm-level

```bash
helm -n kube-system list
```

```bash
helm -n kube-system status aws-load-balancer-controller
```

```bash
helm -n kube-system history aws-load-balancer-controller
```

Show the values actually in effect, including chart defaults you did not set:

```bash
helm -n kube-system get values aws-load-balancer-controller --all
```

```bash
helm -n kube-system get manifest aws-load-balancer-controller | head -40
```

```bash
helm -n kube-system get notes aws-load-balancer-controller
```

Render locally without touching the cluster — the fastest way to see what a
values change would actually do:

```bash
helm template aws-load-balancer-controller eks/aws-load-balancer-controller --version "$CHART_VERSION" --values values.yaml | head -60
```

Compare your values against the chart's defaults:

```bash
helm show values eks/aws-load-balancer-controller --version "$CHART_VERSION" > /tmp/alb-defaults.yaml
```

```bash
diff /tmp/alb-defaults.yaml values.yaml | head -40
```

Confirm the chart metadata and the app version it carries:

```bash
helm show chart eks/aws-load-balancer-controller --version "$CHART_VERSION"
```

Dry-run an upgrade before committing to it:

```bash
helm -n kube-system upgrade aws-load-balancer-controller eks/aws-load-balancer-controller --version "$CHART_VERSION" --values values.yaml --dry-run --debug | head -40
```

### Cluster-level

```bash
kubectl -n kube-system get deploy aws-load-balancer-controller
```

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
```

```bash
kubectl get ingressclass
```

Confirm Pod Identity actually injected credentials — this is the check that
catches a service-account name mismatch:

```bash
kubectl -n kube-system exec deploy/aws-load-balancer-controller -- env | grep AWS_
```

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 | grep -iE 'error|denied'
```

---

## ✅ End-to-end test

[`../alb-ingress/demo-ingress.yaml`](../alb-ingress/demo-ingress.yaml) deploys an echo
server behind a real internet-facing ALB.

```bash
kubectl apply -f ../alb-ingress/demo-ingress.yaml
```

```bash
kubectl get ingress -n alb-demo -w
```

When `ADDRESS` is populated, the ALB exists. Capture it:

```bash
export ALB=$(kubectl get ingress echo -n alb-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"
```

```bash
curl -s "http://$ALB/" | head -c 300
```

Inspect the AWS side — target health is where a broken Ingress usually shows up:

```bash
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].{name:LoadBalancerName,scheme:Scheme,state:State.Code,dns:DNSName}" --output table
```

```bash
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'k8s-')].TargetGroupArn" --output text | head -1) --output table
```

```bash
kubectl get targetgroupbindings -A
```

**Recorded result, 2026-08-27:** ALB
`k8s-cloudgeeksdev-145b174035-1811162643.us-east-1.elb.amazonaws.com` returned
**HTTP 200** with the echo server's JSON body, targets `healthy` in IP mode.

Tear the test down:

```bash
kubectl delete -f ../alb-ingress/demo-ingress.yaml
```

---

## 💡 Notes worth keeping

**Share one ALB across Ingresses.** Every Ingress without a group gets its own
ALB, and ALBs are billed per hour. `alb.ingress.kubernetes.io/group.name` merges
them onto one, which is the single biggest cost lever here.

**`target-type: ip` versus `instance`.** IP mode registers pod IPs directly —
fewer hops, works with Fargate, and no NodePort needed. Instance mode requires
a NodePort on every node and adds a kube-proxy hop.

**Subnet discovery is tag-driven.** Public subnets need
`kubernetes.io/role/elb=1` and private subnets `kubernetes.io/role/internal-elb=1`.
The [`vpc`](../../modules/vpc) module sets both. A missing tag produces
`could not discover subnets`, not an obvious error.

**Deleting the Ingress deletes the ALB.** Delete the Kubernetes object, not the
load balancer in the console — otherwise the controller recreates it.

---

## 🧹 Uninstall

```bash
helm -n kube-system uninstall aws-load-balancer-controller
```

CRDs are deliberately left behind by `helm uninstall`. Remove them only if you
are sure nothing else uses them:

```bash
kubectl delete crd ingressclassparams.elbv2.k8s.aws targetgroupbindings.elbv2.k8s.aws
```

---

## 📚 References

| Topic | Link |
|---|---|
| Controller documentation | https://kubernetes-sigs.github.io/aws-load-balancer-controller/ |
| Ingress annotations reference | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/ |
| Service (NLB) annotations reference | https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/ |
| EKS user guide - load balancing | https://docs.aws.amazon.com/eks/latest/userguide/eks-networking-add-ons.html |
| EKS subnet discovery | https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html |
| EKS Pod Identity | https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html |
| Helm chart source | https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller |
