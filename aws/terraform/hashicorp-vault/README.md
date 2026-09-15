# 🔐 AWS HashiCorp Vault for eks

- 1st Run Bash Script these will certs in kubernetes secret vault namespace

```bash
k create ns vault
chmod +x tls-cloudflare.sh
./tls-cloudflare.sh

kubectl create secret generic vault-tls \
  --namespace vault \
  --from-file=vault.ca=/mnt/tls/ca.pem \
  --from-file=vault.crt=/mnt/tls/vault.pem \
  --from-file=vault.key=/mnt/tls/vault-key.pem

kubectl create secret generic vault-tls \
  --namespace vault \
  --from-file=vault.ca=ca.pem \
  --from-file=vault.crt=vault.pem \
  --from-file=vault.key=vault-key.pem
```

- 2nd Install the HashiCorp Vault Helm chart
```bash
helm repo ls
helm repo add hashicorp https://helm.releases.hashicorp.com
helm search repo hashicorp
helm search repo hashicorp/vault --versions
helm show values hashicorp/vault --version 0.28.1
# helm show values hashicorp/vault --version 0.28.1 > vault-values.yaml
helm repo update

helm -n vault upgrade --install vault hashicorp/vault --version 0.28.1 --values eks-values.yaml --create-namespace --wait
```

- 4th Run the KMS this will create the serivce account with oidc and overide the existing vault service account
```bash
bash -uvx ./kms.sh
```

- 5th 
```bash
helm -n vault upgrade --install vault hashicorp/vault --version 0.28.1 --values eks-values.yaml --create-namespace --wait 
```

- Manually add annotation 
```bash
# From cloudformation stack see the role get the arn

k edit sa/vault -n vault
eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>



apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::058264369563:role/eksctl-cloudgeeks-eks-dev-addon-iamserviceacc-Role1-8z5zkEXDHGO4
    meta.helm.sh/release-name: vault
    meta.helm.sh/release-namespace: vault
  creationTimestamp: "2024-07-17T05:23:26Z"
  labels:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: vault
    helm.sh/chart: vault-0.28.1
  name: vault
  namespace: vault
  resourceVersion: "43591"
  uid: 536c89fa-48b3-4938-95de-f6d1d749b17d
```

- Unseal the Vault & copy the keys in secure place
```bash
kubectl -n vault exec -it vault-0 -- vault operator init
```

### 🔑 Enable k8s auth

Note: When pod run as a service account, it will have a token mounted at /var/run/secrets/kubernetes.io/serviceaccount/token. This token is used to authenticate with the Kubernetes API. The token is scoped to a specific namespace, so it can only access resources in that namespace.

```bash
kubectl -n vault exec -it vault-0 -- sh

vault login
vault auth enable kubernetes

vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host=https://kubernetes.default.svc \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

- Error: failed to login add (ca.pem) simply rerun the command
```bash
vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host=https://kubernetes.default.svc \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```
- Application to Access Secrets in Vault, we need to setup the policy in vault, in order inject secrets in application pod
- Basic Secret Injection
- In order for us to start using secrets in vault, we need to setup a policy.

```bash
#Create a role for our app

kubectl -n vault exec -it vault-0 -- sh

vault write auth/kubernetes/role/basic-secret-role \
   bound_service_account_names="basic-secret" \
   bound_service_account_namespaces="example-app" \
   policies="basic-secret-policy"

vault write auth/kubernetes/role/basic-secret-role \
   bound_service_account_names="basic-secret" \
   bound_service_account_namespaces="example-app" \
   policies="basic-secret-policy" \
   ttl=1h
```

- vault
```bash
vault read auth/kubernetes/config
```

- The above maps our Kubernetes service account, used by our pod, to a policy. Now lets create the policy to map our service account to a bunch of secrets.

```bash
kubectl -n vault exec -it vault-0 -- sh 

cat <<EOF > /home/vault/app-policy.hcl
path "secret/data/basic-secret/*" {
  capabilities = ["read"]
}
EOF
vault policy write basic-secret-policy /home/vault/app-policy.hcl
```

- Now our service account for our pod can access all secrets under secret/basic-secret/* Lets create some secrets.

```bash
kubectl -n vault exec -it vault-0 -- sh 
vault secrets enable -path=secret/ kv-v2
vault kv put secret/basic-secret/helloworld username=dbuser password=12345678
```

- Vault Policy troubleshooting
```bash
vault kv get secret/basic-secret/helloworld
```

- Lets deploy our app and see if it works
```bash
kubectl apply -f deployment.yaml
kubectl -n example-app get pods
```

- issues
- https://github.com/hashicorp/vault/issues/19952

- VAULT HA Raft Mode
```explain
 this setup is using Vault in High Availability (HA) mode with Raft storage. Here's what happens if one node goes down and information about data replication:

If one node goes down:

The Vault cluster will continue to operate as long as a majority of nodes (quorum) are still available. In this case, with 3 replicas, the cluster can tolerate one node failure.
If the failed node was the leader, an automatic leader election will occur among the remaining nodes to select a new leader.
The cluster will continue to serve requests through the remaining active nodes.
When the failed node comes back online, it will automatically rejoin the cluster and sync up with the current state.


Data replication:

Yes, the data is being replicated to other nodes. This configuration uses Raft storage, which is a consensus protocol that ensures data consistency across all nodes.
Each node in the Raft cluster maintains a copy of the entire Vault data.
When a write operation occurs, it is first committed to the leader node and then replicated to the follower nodes.
The retry_join configuration in the Raft storage section ensures that nodes can find and connect to each other, facilitating data replication and cluster formation.


Additional points:

The configuration uses AWS EBS for persistent storage (dataStorage section with storageClass: "gp2"), which provides durability for each node's data.
Auto-unsealing is configured using AWS KMS (seal "awskms" section), which allows nodes to automatically unseal themselves after a restart or failure.
TLS is enabled for secure communication between nodes and clients.
The setup includes 3 replicas (replicas: 3), which provides a good balance of availability and consistency.



In summary, this Vault configuration is designed for high availability and data consistency. If one node goes down, the cluster remains operational, and data is continuously replicated across all active nodes to ensure consistency and durability.

Raft mode is not an enterprise feature in Vault. It is available in both the open-source and enterprise versions of Vault.
Raft storage was introduced in Vault 1.2 as an integrated storage option, and it's fully supported in the open-source version. This was a significant addition because it allowed users to set up highly available Vault clusters without relying on external storage backends like Consul.
Key points about Raft in Vault:

Open-source: Raft storage is available in the free, open-source version of Vault.
Integrated: It's built directly into Vault, requiring no external dependencies for HA setup.
Ease of use: Raft simplifies the deployment of HA Vault clusters, especially for users who don't want to manage a separate Consul cluster.
Performance: It's designed to be performant and suitable for production use.
Feature parity: Most features work identically whether you're using Raft or another storage backend.

While Raft itself is not an enterprise feature, Vault Enterprise does offer some additional features that can be used with Raft storage, such as:

Performance Replication
Disaster Recovery Replication
Read Replicas

But for basic HA setup and operation, the Raft storage in open-source Vault is fully functional and production-ready.
```

- Vault BackUp
```backup
vault operator raft snapshot save snapshot.snap

vault operator raft snapshot restore <path-to-snapshot>

kubectl cp ./backups/vault_backup_20240724_120000.snap vault-0:/tmp/
kubectl exec vault-0 -- vault operator raft snapshot restore /tmp/vault_backup_20240724_120000.snap
```
