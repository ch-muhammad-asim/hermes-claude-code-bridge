#!/bin/bash
set -e

NAMESPACE="vault"
CSR_NAME="vault.svc"
SECRET_NAME="vault-tls"

# Cleanup function to remove existing resources
cleanup() {
  kubectl delete csr $CSR_NAME --ignore-not-found
  kubectl delete secret $SECRET_NAME -n $NAMESPACE --ignore-not-found
}

# Run cleanup before starting the process
cleanup

# Create the private key
openssl genrsa -out vault.key 2048

# Create the vault-csr.conf file
cat > vault-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
encrypt_key = yes
default_md = sha256
distinguished_name = app_serving
req_extensions = v3_req
[ app_serving ]
O = system:nodes
CN = system:node:*.vault.svc.cluster.local
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.vault-internal
DNS.2 = *.vault-internal.vault.svc.cluster.local
DNS.3 = *.vault
DNS.4 = vault
DNS.5 = vault-active.vault.svc.cluster.local
DNS.6 = vault.vault.svc.cluster.local
DNS.7 = vault.vault.svc
IP.1 = 127.0.0.1
EOF

# Generate the CSR using the vault-csr.conf file
openssl req -new -key vault.key -out vault.csr -config vault-csr.conf

# Create the vault-csr.yaml file
cat <<EOF > vault-csr.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $CSR_NAME
spec:
  signerName: kubernetes.io/kubelet-serving
  request: $(cat vault.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# Apply the CSR to the Kubernetes cluster
kubectl apply -f vault-csr.yaml

# Approve the CSR
kubectl certificate approve $CSR_NAME

# Wait for the certificate to be issued
echo "Waiting for the certificate to be issued..."

# Loop to check for the certificate and retrieve it
for i in {1..60}; do
  cert=$(kubectl get csr $CSR_NAME -o jsonpath='{.status.certificate}')
  if [[ -n "$cert" ]]; then
    echo "$cert" | base64 --decode > vault.crt
    echo "Certificate retrieved successfully."
    break
  fi
  echo "Certificate not available yet, waiting... (Attempt $i of 60)"
  sleep 5
done

# Check if certificate was successfully retrieved
if [[ ! -s vault.crt ]]; then
  echo "Failed to retrieve the certificate."
  kubectl get csr $CSR_NAME -o yaml
  exit 1
fi

# Retrieve the Kubernetes CA certificate
kubectl config view \
--raw \
--minify \
--flatten \
-o jsonpath='{.clusters[].cluster.certificate-authority-data}' \
| base64 --decode > vault.ca

# Verify the certificate
openssl verify -verbose -CAfile vault.ca vault.crt

# Create the Kubernetes secret
kubectl create secret generic $SECRET_NAME \
   -n $NAMESPACE \
   --from-file=vault.key=vault.key \
   --from-file=vault.crt=vault.crt \
   --from-file=vault.ca=vault.ca

echo "TLS secret created successfully."