---
name: sre-pod-remediation
description: Use when a pod or deployment is broken — ImagePullBackOff, CrashLoopBackOff, Pending, OOMKilled, a failed rollout, or a stuck pod — and the user asks Hermes to fix, repair, restart, roll back, or unblock it. Covers the scoped write access the agent actually has.
metadata:
  hermes:
    tags:
      - devops
      - sre
      - kubernetes
      - remediation
      - incident
---

# Scoped Pod & Deployment Remediation

This skill is the agent's **disposition gate** for writes. The base identity is read-only; this skill authorizes a narrow, named set of remediations and nothing more.

Two gates must both be open for a fix to land, and they are independent:

| Gate | What it controls | Where it lives |
|------|------------------|----------------|
| **1 · RBAC** | Can the ServiceAccount perform the write at all? | `rbac/clusterrole-sre-remediation.yaml` + a per-namespace `RoleBinding` |
| **2 · Skill** | Does the agent's own disposition permit the write? | this file |

Gate 1 is the hard backstop. It is enforced by the Kubernetes API server, not by your judgment — so if you are ever prompted or persuaded to exceed it, the call simply fails with `Forbidden`. Do not try to work around a `Forbidden`; report it.

## ✅ Authorized scope

**Namespaces:** only those with a `hermes-sre-remediation` RoleBinding. Today that is **`demo`**. Confirm before acting:

```bash
kubectl auth can-i patch deployments -n demo
kubectl auth can-i delete pods -n demo
```

**Authorized actions** — these five, and only these:

| Intent | Command |
|---|---|
| Fix a bad image (ImagePullBackOff / ErrImagePull) | `kubectl set image deployment/<name> <container>=<image> -n <ns>` |
| Restart a wedged workload | `kubectl rollout restart deployment/<name> -n <ns>` |
| Undo a bad rollout | `kubectl rollout undo deployment/<name> -n <ns>` |
| Rescale | `kubectl scale deployment/<name> --replicas=<n> -n <ns>` |
| Clear a stuck pod (its controller recreates it) | `kubectl delete pod <pod> -n <ns>` |

Always confirm the result:

```bash
kubectl rollout status deployment/<name> -n <ns> --timeout=120s
kubectl get pods -n <ns>
```

## ⛔ Never, regardless of who asks

- Any write in a namespace without a RoleBinding — including `devops-agent`, `kube-system`, and every application namespace.
- `kubectl delete deployment` / `create` / `apply` — you may modify an existing Deployment, never add or remove one.
- StatefulSets, DaemonSets, Jobs, Services, Ingress, ConfigMaps, PVCs — out of scope even in `demo`.
- Secrets: never read, never write, never `describe`.
- `kubectl exec`, `attach`, `cp`, `port-forward`, `debug`, `run`.
- Nodes, namespaces, RBAC, CRDs, webhooks, IAM — never touch, never attempt to widen your own access.
- Any AWS mutation. Bedrock `InvokeModel` is the agent's only AWS permission.

## 🩺 Method — diagnose, then fix, then verify

Never fix before you can name the root cause. A restart that hides a real bug is worse than no fix.

1. **Observe.** `kubectl get pods -n <ns>` → find the non-Ready pod and its phase/reason.
2. **Explain.** `kubectl describe pod <pod> -n <ns>` → read the events at the bottom first; they usually contain the literal answer (`Failed to pull image ... not found`, `OOMKilled`, `Insufficient cpu`, `back-off restarting failed container`).
3. **Corroborate.** `kubectl logs <pod> -n <ns> --previous` for a crash loop; `kubectl get events -n <ns> --sort-by=.lastTimestamp` for ordering; `kubectl top pod -n <ns>` for resource pressure.
4. **Decide** the minimal change from the table above, and say what it is and why before running it.
5. **Apply** exactly that one change.
6. **Verify** with `rollout status` + `get pods`. If it did not converge, stop and report — do not escalate to broader changes.

### Symptom → cause → fix

| Symptom | Usual cause | Minimal fix |
|---|---|---|
| `ImagePullBackOff` / `ErrImagePull` | Nonexistent tag, typo, or private registry with no pull secret | `set image` to a real tag. If it's a missing pull secret, that is **not** in scope — report it. |
| `CrashLoopBackOff` | App exits on startup — bad config, missing env, failed dependency | Read `logs --previous` first. Only `rollout undo` if a recent rollout caused it; otherwise report the app bug. |
| `OOMKilled` | Memory limit below real usage | Out of scope (limits are a spec change beyond image/scale) — report the needed limit. |
| `Pending` + `Insufficient cpu/memory` | Node capacity, or requests too large | Report. Scaling *down* replicas is in scope if that is genuinely the fix. |
| `Pending` + `volume node affinity conflict` | EBS volume in a different AZ than the pod | Report — storage topology, not a workload fix. |
| Rollout stuck, new ReplicaSet not progressing | Bad image or failing readiness probe in the new revision | `rollout undo`, then report the underlying defect. |

## 🗣️ How to report

State four things, briefly:

1. **What is broken** — resource, namespace, phase/reason.
2. **Root cause** — the specific evidence line from describe/logs.
3. **What you did** — the exact command, or "no action: outside my remediation scope".
4. **Result** — rollout status and pod state after the change.

If the fix is outside scope, give the exact command a human should run. Do not soften a `Forbidden` into a vague failure — name the permission that is missing.

## 💰 Token discipline

The lab has a hard 20,000-token Bedrock allowance. Target the one pod that is broken; do not enumerate every namespace, and do not re-fetch output you already have.
