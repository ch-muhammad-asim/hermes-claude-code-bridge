# 🐙 ARGOCD HA Setup

- Helm Commands
```commandline
# Add the ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm

# Update the Helm repositories
helm repo update

# Search for ArgoCD in the Helm repository
helm search repo argo/argo-cd

# Show the values for the ArgoCD Helm chart
helm show values argo/argo-cd

# Search for specific versions of the ArgoCD Helm chart
helm search repo argo/argo-cd --versions

# Show chart information for a specific version (e.g., 7.5.0)
helm show chart argo/argo-cd --version 7.5.0

# Show the README for a specific version
helm show readme argo/argo-cd --version 7.5.0

# Show the values for a specific version
helm show values argo/argo-cd --version 7.5.0

# Install the ArgoCD Helm chart
helm upgrade --install argocd argo/argo-cd --version 7.5.0 --namespace argocd --create-namespace -f values.yaml --wait
```

- Create a deploy key for the ArgoCD helm repository (where your helm charts are stored)
```commandline
# Generate a new SSH key pair type ed25519
ssh-keygen -t ed25519 -C "argocd" -f argocd
```

