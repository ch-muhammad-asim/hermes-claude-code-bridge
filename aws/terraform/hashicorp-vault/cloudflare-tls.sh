#!/bin/bash

# Update the package list and install curl
apt-get update && apt-get install -y curl

# Download cfssl and cfssljson binaries
curl -L https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssl_1.6.4_linux_amd64 -o /usr/local/bin/cfssl
curl -L https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssljson_1.6.4_linux_amd64 -o /usr/local/bin/cfssljson

# Make the binaries executable
chmod +x /usr/local/bin/cfssl
chmod +x /usr/local/bin/cfssljson

# Create the directory for TLS files and navigate to it
mkdir -p /mnt/tls
cd /mnt/tls

# Create the CA configuration file
cat << EOF > /mnt/tls/ca-config.json
{
  "signing": {
    "default": {
      "expiry": "175200h"
    },
    "profiles": {
      "default": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "175200h"
      }
    }
  }
}
EOF

# Create the Certificate Signing Request (CSR) file
cat << EOF > /mnt/tls/ca-csr.json
{
  "hosts": [
    "*.vault.svc.cluster.local",
    "*.vault-internal",
    "*.vault-internal.vault.svc.cluster.local",
    "*.vault",
    "vault",
    "vault-active.vault.svc.cluster.local",
    "127.0.0.1",
    "localhost"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PK",
      "L": "Lahore",
      "O": "cloudgeeks",
      "OU": "IT",
      "ST": "Punjab"
    }
  ]
}
EOF

# Generate the CA certificate
cfssl gencert -initca /mnt/tls/ca-csr.json | cfssljson -bare /mnt/tls/ca

# Generate the Vault certificate
cfssl gencert \
  -ca=/mnt/tls/ca.pem \
  -ca-key=/mnt/tls/ca-key.pem \
  -config=/mnt/tls/ca-config.json \
  -hostname="*.vault.svc.cluster.local,*.vault-internal,*.vault-internal.vault.svc.cluster.local,*.vault,vault,vault-active.vault.svc.cluster.local,127.0.0.1,localhost" \
  -profile=default \
  /mnt/tls/ca-csr.json | cfssljson -bare /mnt/tls/vault
