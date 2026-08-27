#!/bin/bash
set -x

# Set environment variables
export CLUSTER_NAME="my-cluster"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="602401143452"  # AWS ECR account for the load balancer controller
# https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
export MY_AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export VPC_ID="$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

# URL for the IAM policy used by AWS Load Balancer Controller
IAM_POLICY_URL="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"

# Download the latest IAM policy for the AWS Load Balancer Controller
curl -o iam_policy_latest.json ${IAM_POLICY_URL}

# Create IAM Policy using the downloaded policy document
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy_latest.json || echo "IAM policy already exists."

# Create an IAM service account for the AWS Load Balancer Controller using eksctl
eksctl create iamserviceaccount \
    --region ${AWS_DEFAULT_REGION} \
    --name aws-load-balancer-controller \
    --namespace kube-system \
    --cluster ${CLUSTER_NAME} \
    --attach-policy-arn arn:aws:iam::${MY_AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve

# Verify the creation of the IAM service account
eksctl get iamserviceaccount --cluster ${CLUSTER_NAME}

# Describe the service account in the kube-system namespace
kubectl describe sa aws-load-balancer-controller -n kube-system

# Add the EKS Helm charts repository
helm repo add eks https://aws.github.io/eks-charts

# Update local Helm repositories to ensure you have the latest versions
helm repo update

# Install or upgrade the AWS Load Balancer Controller using Helm
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --version 1.8.2 \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${AWS_DEFAULT_REGION} \
  --set vpcId=${VPC_ID} \
  --set image.repository=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/amazon/aws-load-balancer-controller

echo "AWS Load Balancer Controller installation completed."
