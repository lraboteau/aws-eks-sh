#!/bin/bash

set -euo pipefail

# ====== CONFIGURATION ======
CLUSTER_NAME="eks-aws-standard"
REGION="eu-west-3"
K8S_VERSION="1.31"
NODE_GROUP_NAME="ng-standard"
NODE_TYPE="t3.medium"
NODE_COUNT=2
STACK_NAME="eks-vpc-stack"
CLUSTER_ROLE_NAME="eksClusterRole"
NODE_ROLE_NAME="eksNodeRole"

echo "Step 1: Create IAM Roles..."

# --- Create Cluster Role ---
CLUSTER_TRUST_FILE=$(mktemp)
cat > "$CLUSTER_TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

if ! aws iam get-role --role-name "$CLUSTER_ROLE_NAME" &>/dev/null; then
  aws iam create-role \
    --role-name "$CLUSTER_ROLE_NAME" \
    --assume-role-policy-document file://"$CLUSTER_TRUST_FILE"
  aws iam attach-role-policy \
    --role-name "$CLUSTER_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
  echo "Cluster IAM role created."
else
  echo "Cluster IAM role already exists."
fi
rm -f "$CLUSTER_TRUST_FILE"

# --- Create Node Group Role ---
NODE_TRUST_FILE=$(mktemp)
cat > "$NODE_TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

if ! aws iam get-role --role-name "$NODE_ROLE_NAME" &>/dev/null; then
  aws iam create-role \
    --role-name "$NODE_ROLE_NAME" \
    --assume-role-policy-document file://"$NODE_TRUST_FILE"
  aws iam attach-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
  aws iam attach-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  aws iam attach-role-policy \
    --role-name "$NODE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  echo "Node group IAM role created."
else
  echo "Node group IAM role already exists."
fi
rm -f "$NODE_TRUST_FILE"

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name "$CLUSTER_ROLE_NAME" --query "Role.Arn" --output text)
NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query "Role.Arn" --output text)

# ====== VPC SETUP ======
echo "Step 2: Create EKS VPC..."

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --template-url https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-06-10/amazon-eks-vpc-sample.yaml \
    --capabilities CAPABILITY_IAM
  echo "Waiting for VPC stack creation..."
  aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
else
  echo "VPC stack $STACK_NAME already exists."
fi

# ====== EXTRACT VPC OUTPUTS ======
SUBNET_IDS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" \
  --output text)

SECURITY_GROUP_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroups'].OutputValue" \
  --output text)

# POSIX-safe split using cut
SUBNET1=$(echo "$SUBNET_IDS" | cut -d',' -f1)
SUBNET2=$(echo "$SUBNET_IDS" | cut -d',' -f2)

echo "Using subnets: $SUBNET1 and $SUBNET2"
echo "Using security group: $SECURITY_GROUP_ID"

# Validate subnets exist
aws ec2 describe-subnets --subnet-ids "$SUBNET1" "$SUBNET2" --region "$REGION" > /dev/null

# ====== CREATE EKS CLUSTER ======
echo "Step 3: Create EKS Cluster..."

if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  aws eks create-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --kubernetes-version "$K8S_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config subnetIds=$SUBNET1,$SUBNET2,securityGroupIds=$SECURITY_GROUP_ID
  echo "Waiting for EKS cluster to become ACTIVE..."
  aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION"
else
  echo "Cluster $CLUSTER_NAME already exists."
fi

# ====== CONFIGURE KUBECTL ======
echo "Step 4: Configure kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
echo "kubectl configured."

# ====== CREATE MANAGED NODE GROUP ======
echo "Step 5: Create managed node group..."

if ! aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODE_GROUP_NAME" --region "$REGION" &>/dev/null; then
  aws eks create-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --region "$REGION" \
    --nodegroup-name "$NODE_GROUP_NAME" \
    --subnets "$SUBNET1" "$SUBNET2" \
    --node-role "$NODE_ROLE_ARN" \
    --scaling-config minSize=1,maxSize=4,desiredSize=$NODE_COUNT \
    --instance-types "$NODE_TYPE" \
    --ami-type AL2_x86_64
  echo "Waiting for node group to become ACTIVE..."
  aws eks wait nodegroup-active \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP_NAME" \
    --region "$REGION"
else
  echo "Node group $NODE_GROUP_NAME already exists."
fi

# ====== DONE ======
echo "EKS cluster $CLUSTER_NAME is ready with node group $NODE_GROUP_NAME!"
kubectl get nodes
