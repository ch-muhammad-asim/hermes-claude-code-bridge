# 🎬 Hermes SRE Demo — diagnose *and* fix a broken pod

A Kustomize overlay that breaks a Deployment on purpose so Hermes can find the root
cause and repair it. This is the agentic-SRE showcase.

> ⚠️ **Demo/sandbox only.** It grants a real (if narrow) write. Revert with step 4.

## ⚡ Quick start

k3s:

```bash
kubectl apply -k hermes-agent/aws-bedrock/sre-demo/k3s
```

EKS:

```bash
kubectl apply -k hermes-agent/aws-bedrock/sre-demo
```

Then ask Hermes *"the demo-nginx deployment in the demo namespace is broken, diagnose
and fix it"* — via the dashboard, Slack, or one-shot from the pod:

```bash
kubectl -n devops-agent exec hermes-agent-0 -c hermes -- sh -lc 'export HERMES_HOME=/opt/data PATH=/opt/data/bin:$PATH; /opt/hermes/.venv/bin/hermes --cli --yolo --accept-hooks -z "The demo-nginx deployment in the demo namespace is broken. Diagnose the root cause and fix it. Then confirm the rollout succeeded."'
```

> 🛑 **`apply -k`, not `apply -f`** — these are Kustomize overlays. Pointing `-f` at a
> `kustomization.yaml` fails with *`no matches for kind "Kustomization"`*.

## 🚧 It takes *two* gates here, not three

The read-only posture is defended in depth. This deployment has two independent gates,
both already open in the base — so the overlay adds only the broken workload:

| Gate | What it controls | Where |
|------|------------------|-------|
| **1 · RBAC** | Can the ServiceAccount write at all? | `kubernetes/rbac/clusterrole-sre-remediation.yaml` + a per-namespace RoleBinding |
| **2 · Skill** | Does Hermes's own disposition permit a write? | `kubernetes/skills/sre-pod-remediation/SKILL.md` |

Gate 2 is the one people miss: with RBAC open but a skill that says *"never mutate
production"*, the agent declines on principle.

**The third gate from [`../../../hermes-agent-devops-demo`](../../../hermes-agent-devops-demo)
does not exist on this path.** That demo also has to open the Claude Code harness tool
policy (`CLAUDE_CODE_ALLOWED_TOOLS`), because Hermes drives Claude Code there. Here
Hermes talks to Bedrock through the bridge and runs `kubectl` with its own `terminal`
tool — there is no harness policy to open. RBAC is therefore the *only*
machine-enforced gate, which is exactly why it is bound per namespace rather than
cluster-wide as the reference demo does.

## 📦 Files

| File | What it does |
|------|--------------|
| `base/01-broken-deployment.yaml` | `demo-nginx` on `nginx:faulty` — a tag that does not exist → **ImagePullBackOff** |
| `base/kustomization.yaml` | The workload alone, so both overlays consume it as a directory |
| `kustomization.yaml` | EKS overlay: `../kubernetes` + `base` |
| `k3s/kustomization.yaml` | k3s overlay: `../../overlays/k3s` + `../base` |

The `demo` namespace and the RoleBinding that authorizes the fix live in the **base**
(`kubernetes/rbac/`), not here — the agent's permissions are part of its deployment,
not of a demo.

## ▶️ Walkthrough

**1. Confirm it is broken.**

```bash
kubectl -n demo get pods
```

```text
NAME                         READY   STATUS         RESTARTS   AGE
demo-nginx-8b9fd5594-7c9wq   0/1     ErrImagePull   0          33s
```

**2. Confirm the gates.** The first three `yes`, the rest `no`:

```bash
kubectl auth can-i patch deployments -n demo --as=system:serviceaccount:devops-agent:hermes-agent
```

```bash
for q in "delete pods -n demo" "update deployments/scale -n demo" "patch deployments -n devops-agent" "get secrets -n demo" "create deployments -n demo" "create pods/exec -n demo"; do echo "$q -> $(kubectl auth can-i ${=q} --as=system:serviceaccount:devops-agent:hermes-agent)"; done
```

**3. Ask Hermes to fix it.** A recorded run:

```text
✅ Fixed and verified

What was broken: demo-nginx deployment in demo namespace, 0/1 ready,
                 pod stuck in ImagePullBackOff
Root cause:      nonexistent image tag `nginx:faulty`. The kubelet error was
                 explicit: failed to resolve reference
                 'docker.io/library/nginx:faulty': not found
Action taken:    kubectl set image deployment/demo-nginx demo-nginx=nginx:stable-alpine -n demo
Result:          rollout successfully rolled out; 1/1 READY
```

Note it chose `set image` — one of the five commands the skill authorizes — rather
than deleting and recreating the Deployment, which RBAC would have refused anyway.

Verify independently:

```bash
kubectl -n demo get deploy demo-nginx -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**4. Revert.** Removes the broken workload; the agent and its RBAC stay:

```bash
kubectl delete -k hermes-agent/aws-bedrock/sre-demo/k3s
```

To revoke the write capability entirely, drop the binding — the read-only base is
untouched:

```bash
kubectl -n demo delete rolebinding hermes-sre-remediation
```

## 💰 Token cost

One full diagnose-and-fix run measured **7 Bedrock calls, 40 uncached input tokens,
950 output tokens**, with 96,931 tokens served from prompt cache against 21,869 cache
writes. Read the accounting yourself:

```bash
kubectl -n devops-agent logs hermes-agent-0 -c bedrock-claude-bridge | grep "usage model"
```
