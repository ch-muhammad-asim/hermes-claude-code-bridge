#!/bin/bash

# Variables
AWS_REGION="us-east-1"  # Replace with your AWS region
EKS_CLUSTER_NAME="cloudgeeks-eks-dev"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
KMS_KEY_ALIAS="alias/hashicorp-vault-auto-unseal-key"
POLICY_NAME="VaultKMSPolicy"
SERVICE_ACCOUNT_NAME="vault"
SERVICE_ACCOUNT_NAMESPACE="vault"

# Function to check if a command was successful
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

echo "Setting up KMS and IAM for Vault in EKS"

# Step 1: Create KMS Key
echo "Creating KMS key..."
KMS_KEY_OUTPUT=$(aws kms create-key --description "Key for Vault auto-unseal in EKS" --region $AWS_REGION)
check_success "Failed to create KMS key"

KMS_KEY_ID=$(echo $KMS_KEY_OUTPUT | jq -r .KeyMetadata.KeyId)
echo "KMS Key created with ID: $KMS_KEY_ID"

# Step 2: Create an alias for the key
echo "Creating alias for KMS key..."
aws kms create-alias --alias-name $KMS_KEY_ALIAS --target-key-id $KMS_KEY_ID --region $AWS_REGION
check_success "Failed to create KMS key alias"

# Step 3: Get EKS cluster's OIDC provider URL
echo "Getting EKS cluster OIDC provider URL..."
OIDC_PROVIDER=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text --region $AWS_REGION | sed 's|https://||')
check_success "Failed to get OIDC provider URL"

# Step 4: Create IAM policy for KMS access
echo "Creating IAM policy for KMS access..."

# Create a local policy file
cat << EOF > vault_kms_policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:DescribeKey"
            ],
            "Resource": "arn:aws:kms:$AWS_REGION:$ACCOUNT_ID:key/$KMS_KEY_ID"
        }
    ]
}
EOF

# Create the IAM policy using the local file
aws iam create-policy --policy-name $POLICY_NAME --policy-document file://vault_kms_policy.json
check_success "Failed to create IAM policy"

# Remove the local policy file
rm vault_kms_policy.json

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

# Step 5: Create IAM role for the Vault service account
echo "Creating IAM role for Vault service account..."
eksctl create iamserviceaccount \
    --name $SERVICE_ACCOUNT_NAME \
    --namespace $SERVICE_ACCOUNT_NAMESPACE \
    --cluster $EKS_CLUSTER_NAME \
    --attach-policy-arn $POLICY_ARN \
    --approve \
    --override-existing-serviceaccounts \
    --region $AWS_REGION
check_success "Failed to create IAM service account"

echo "Setup complete!"
echo "KMS Key ID: $KMS_KEY_ID"
echo "KMS Key Alias: $KMS_KEY_ALIAS"
echo "IAM Policy ARN: $POLICY_ARN"
echo ""
echo "Next steps:"
echo "1. Update your Helm values.yaml with the following:"
echo "   server:"
echo "     extraEnvironmentVars:"
echo "       VAULT_AWSKMS_SEAL_KEY_ID: \"$KMS_KEY_ID\""
echo "     serviceAccount:"
echo "       create: false"
echo "       name: $SERVICE_ACCOUNT_NAME"
echo "   ha:"
echo "     raft:"
echo "       config: |"
echo "         seal \"awskms\" {"
echo "           region     = \"$AWS_REGION\""
echo "           kms_key_id = \"\${VAULT_AWSKMS_SEAL_KEY_ID}\""
echo "         }"
echo ""
echo "2. Deploy or upgrade your Vault Helm release with the updated values."