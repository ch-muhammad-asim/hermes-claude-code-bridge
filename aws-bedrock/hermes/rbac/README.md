# 🔐 RBAC — read-only everywhere, scoped write in one place

Kubernetes RBAC is the **only machine-enforced gate** on this deployment. There is no
Claude Code harness policy on the native-provider path (Hermes runs `kubectl` with its
own `terminal` tool), so these files are what actually stops the agent — not the prompt,
not the skill, not the model's judgement. RBAC is deny-by-default: anything not listed
is forbidden at the API server, even under prompt injection.

| File | Kind | Grants |
|---|---|---|
| `namespace.yaml` | Namespace | `devops-agent` — where the agent runs |
| `namespace-demo.yaml` | Namespace | `demo` — the one namespace it may repair |
| `serviceaccount.yaml` | ServiceAccount | `hermes-agent`. **No annotation** — EKS Pod Identity binds from the AWS side, unlike IRSA or GKE Workload Identity |
| `clusterrole-readonly.yaml` | ClusterRole + Binding | `get/list/watch` cluster-wide: pods, nodes, events, workloads, ingress, storage, metrics, RBAC (for diagnosing authz), webhooks |
| `role-namespace-readonly.yaml` | Role (`devops-agent`) | Namespace-local reads the cluster role withholds — chiefly **configmaps**, denied cluster-wide because teams put sensitive values in them |
| `rolebinding-namespace-readonly.yaml` | RoleBinding | Binds the above to the ServiceAccount |
| `clusterrole-sre-remediation.yaml` | ClusterRole | The scoped write: Deployment `update/patch`, `deployments/scale`, Pod `delete`. **Grants nothing on its own** |
| `rolebinding-sre-remediation.yaml` | RoleBinding (`demo`) | Scopes that ClusterRole to `demo` only |

## 🎯 Why a RoleBinding, not a ClusterRoleBinding

A `RoleBinding` that references a `ClusterRole` grants those rules **only inside its own
namespace**. So the remediation permissions are defined once and each namespace opts in
explicitly. The reference demo in
[`../../../hermes-agent-devops-demo`](../../../hermes-agent-devops-demo) uses a
`ClusterRoleBinding`, which permits Deployment writes in *every* namespace — including
`kube-system`. This is deliberately tighter.

Authorize another namespace by copying `rolebinding-sre-remediation.yaml` and changing
`metadata.namespace`. Revoke everything with a single delete; the read-only base is
untouched:

```bash
kubectl -n demo delete rolebinding hermes-sre-remediation
```

## ✅ Verify the boundary

Never assume — impersonate the ServiceAccount and ask the API server. The first group
must be `yes`, the second `no`:

```bash
for q in "patch deployments -n demo" "delete pods -n demo" "update deployments/scale -n demo" "get pods -n kube-system"; do echo "$q -> $(kubectl auth can-i ${=q} --as=system:serviceaccount:devops-agent:hermes-agent)"; done
```

```bash
for q in "patch deployments -n devops-agent" "patch deployments -n kube-system" "get secrets -n demo" "create deployments -n demo" "delete deployments -n demo" "create pods/exec -n demo" "delete pods -n kube-system"; do echo "$q -> $(kubectl auth can-i ${=q} --as=system:serviceaccount:devops-agent:hermes-agent)"; done
```

## ⛔ Never granted, anywhere

`secrets` (any verb) · `create`/`delete` on Deployments · StatefulSets, DaemonSets,
Jobs, Services, ConfigMaps, PVC writes · `pods/exec`, `pods/attach`, `pods/portforward`
· nodes · namespaces · RBAC · CRDs · webhooks.

Pod `delete` is the only destructive verb, and it is safe precisely because pods are
controller-owned and disposable — the ReplicaSet reconciles a replacement.
