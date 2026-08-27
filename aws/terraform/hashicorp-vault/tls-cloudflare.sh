#!/usr/bin/env bash

set -euo pipefail

# Constants
CFSSL_VERSION="1.6.5"
CFSSL_URL="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64"
CFSSLJSON_URL="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64"
TLS_DIR="./tls"

# Certificate validity period (100 years in hours)
CERT_VALIDITY="876000h"

# Hostname variables
CLUSTER_DOMAIN="cluster.local"
SERVICE_NAME="vault"
NAMESPACE="vault"
INTERNAL_DOMAIN="vault-internal"

# Custom domain variables
CUSTOM_DOMAIN="saqlainmushtaq.com"
CUSTOM_SUBDOMAINS=("vault" "dev.vault")

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install dependencies
install_dependencies() {
    log "Updating package list and installing curl..."
    if ! apt-get update && apt-get install -y curl; then
        log "Error: Failed to install curl. Exiting."
        exit 1
    fi
}

# Function to download and install CFSSL tools
install_cfssl_tools() {
    log "Downloading and installing CFSSL tools..."
    curl -L "${CFSSL_URL}" -o /usr/local/bin/cfssl
    curl -L "${CFSSLJSON_URL}" -o /usr/local/bin/cfssljson
    chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson

    if ! command_exists cfssl || ! command_exists cfssljson; then
        log "Error: Failed to install CFSSL tools. Exiting."
        exit 1
    fi
}

# Function to create TLS directory
create_tls_directory() {
    log "Creating TLS directory..."
    mkdir -p "${TLS_DIR}"
    cd "${TLS_DIR}"
}

# Function to create CA configuration file
create_ca_config() {
    log "Creating CA configuration file..."
    cat << EOF > "ca-config.json"
{
  "signing": {
    "default": {
      "expiry": "${CERT_VALIDITY}"
    },
    "profiles": {
      "default": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "${CERT_VALIDITY}"
      }
    }
  }
}
EOF
}

# Function to create Certificate Signing Request (CSR) file
create_csr() {
    log "Creating Certificate Signing Request (CSR) file..."
    
    # Generate the list of hosts including custom domains
    local hosts=(
        "*.${SERVICE_NAME}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
        "*.${INTERNAL_DOMAIN}"
        "*.${INTERNAL_DOMAIN}.${SERVICE_NAME}.svc.${CLUSTER_DOMAIN}"
        "*.${SERVICE_NAME}"
        "${SERVICE_NAME}"
        "${SERVICE_NAME}-active.${SERVICE_NAME}.svc.${CLUSTER_DOMAIN}"
        "127.0.0.1"
        "localhost"
    )
    
    # Add custom domains
    for subdomain in "${CUSTOM_SUBDOMAINS[@]}"; do
        hosts+=("${subdomain}.${CUSTOM_DOMAIN}")
    done
    
    # Convert array to JSON array
    local json_hosts=$(printf '"%s",' "${hosts[@]}" | sed 's/,$//')
    
    cat << EOF > "ca-csr.json"
{
  "hosts": [${json_hosts}],
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
}

# Function to generate CA certificate
generate_ca_cert() {
    log "Generating CA certificate..."
    if ! cfssl gencert -initca "ca-csr.json" | cfssljson -bare ca; then
        log "Error: Failed to generate CA certificate. Exiting."
        exit 1
    fi
}

# Function to generate Vault certificate
generate_vault_cert() {
    log "Generating Vault certificate..."
    
    # Generate the list of hostnames including custom domains
    local hostnames=(
        "*.${SERVICE_NAME}.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"
        "*.${INTERNAL_DOMAIN}"
        "*.${INTERNAL_DOMAIN}.${SERVICE_NAME}.svc.${CLUSTER_DOMAIN}"
        "*.${SERVICE_NAME}"
        "${SERVICE_NAME}"
        "${SERVICE_NAME}-active.${SERVICE_NAME}.svc.${CLUSTER_DOMAIN}"
        "127.0.0.1"
        "localhost"
    )
    
    # Add custom domains
    for subdomain in "${CUSTOM_SUBDOMAINS[@]}"; do
        hostnames+=("${subdomain}.${CUSTOM_DOMAIN}")
    done
    
    # Convert array to comma-separated string
    local hostname_string=$(IFS=,; echo "${hostnames[*]}")
    
    if ! cfssl gencert \
        -ca="ca.pem" \
        -ca-key="ca-key.pem" \
        -config="ca-config.json" \
        -hostname="${hostname_string}" \
        -profile=default \
        "ca-csr.json" | cfssljson -bare vault; then
        log "Error: Failed to generate Vault certificate. Exiting."
        exit 1
    fi
}

# Main execution
main() {
    log "Starting Vault TLS setup..."
    log "Certificate validity period set to ${CERT_VALIDITY} (100 years)"
    install_dependencies
    install_cfssl_tools
    create_tls_directory
    create_ca_config
    create_csr
    generate_ca_cert
    generate_vault_cert
    log "Vault TLS setup completed successfully."
    log "TLS files are located in: ${TLS_DIR}"
}

main
