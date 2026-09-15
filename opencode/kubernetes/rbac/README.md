# 🔐 rbac/

The **hard backstop** of the read-only posture. Layers 1 and 2 (the OpenCode permission policy and the `kubectl-ro` wrapper) live in config a human can widen; this layer is enforced by the API server, so it holds even if those are misconfigured or the model is prompt-injected.

| File | Resource | Grants |
|------|----------|--------|
| `01-serviceaccount.yaml` | `ServiceAccount/hermes-agent` | The pod's identity — every `kubectl` call the agent makes uses this token |
| `02-role.yaml` | `Role/hermes-namespace-readonly` | Namespace-local reads the ClusterRole withholds — notably **configmaps in `devops-agent`** |
| `03-rolebinding.yaml` | `RoleBinding` | Binds that Role to the SA |
| `04-clusterrole-readonly.yaml` | `ClusterRole` + `ClusterRoleBinding/hermes-opencode-cluster-readonly` | Cluster-wide `get/list/watch` for SRE triage |

## What is deliberately absent

RBAC is deny-by-default, so anything unlisted is forbidden. Never granted, anywhere:

- **`secrets`** — any verb. The agent cannot read or exfiltrate credentials.
- **`create` / `patch` / `update` / `delete`** — no restarts, scaling, edits, or deletions.
- **`pods/exec`, `pods/attach`, `pods/portforward`** — no shell into other workloads.
- **configmaps cluster-wide** — teams sometimes store sensitive values in them; reads are limited to Hermes' own namespace via the Role.
- **`tokenreviews` / `subjectaccessreviews` / `serviceaccounts/token`** — no token minting.

RBAC *read* is granted (roles, rolebindings, clusterroles, clusterrolebindings) so a lead SRE can diagnose "why is this forbidden?" — escalation is impossible because no write verb exists to bind anything new.

## Naming

The cluster-scoped resources are `hermes-opencode-cluster-readonly`, deliberately distinct from the Claude Code deployment's `hermes-cluster-readonly`. ClusterRoles are cluster-scoped: sharing a name would mean `kubectl apply -k` on one stack silently rewriting the other's cluster-wide grant. The rule set itself is identical.

The namespaced resources reuse the Claude stack's names — they're namespace-scoped, so a different namespace isolates them. Deploy only one stack per namespace (both name the StatefulSet `hermes-agent`).

## Verify what the agent can actually do

```bash
SA=system:serviceaccount:devops-agent:hermes-agent
kubectl auth can-i get pods            --as="$SA" -A    # yes
kubectl auth can-i get secrets         --as="$SA" -A    # no
kubectl auth can-i delete pods         --as="$SA" -A    # no
kubectl auth can-i create deployments  --as="$SA" -A    # no
kubectl auth can-i create pods/exec    --as="$SA" -A    # no
```

The agent can run the same check on itself — `kubectl auth can-i` is on the wrapper's allowlist.
