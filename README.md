# AWS EKS Automated Cluster Creation

This workflow automates the end-to-end setup of an Amazon EKS cluster using AWS CLI. It includes IAM role creation, VPC provisioning via CloudFormation, cluster deployment, and managed node group setup.

## Step 1: IAM Role Creation

### Create IAM Role for EKS Cluster

```bash
aws iam create-role --role-name "$CLUSTER_ROLE_NAME" \
  --assume-role-policy-document file://"$CLUSTER_TRUST_FILE"
```

> This role is assumed by the EKS control plane. The `AmazonEKSClusterPolicy` is attached for required permissions.

### Create IAM Role for Worker Nodes

```bash
aws iam create-role --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file://"$NODE_TRUST_FILE"
```

> This EC2-assumed role is used by the worker nodes. It includes:

* `AmazonEKSWorkerNodePolicy`
* `AmazonEC2ContainerRegistryReadOnly`
* `AmazonEKS_CNI_Policy`

The script checks if roles exist before creating them and stores their ARNs for later use.

## Step 2: VPC Provisioning via CloudFormation

```bash
aws cloudformation create-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --template-url https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-06-10/amazon-eks-vpc-sample.yaml \
  --capabilities CAPABILITY_IAM
```

> A default VPC is created using the official EKS sample template if it doesn't already exist. Subnet and security group IDs are extracted from the CloudFormation outputs.

## Step 3: Create the EKS Cluster

```bash
aws eks create-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --kubernetes-version "$K8S_VERSION" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config subnetIds=$SUBNET1,$SUBNET2,securityGroupIds=$SECURITY_GROUP_ID
```

> The cluster is created in the VPC subnets with the specified IAM role. The script waits until the cluster status is `ACTIVE`.

## Step 4: Configure `kubectl`

```bash
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
```

> This updates your kubeconfig so you can access the new cluster using `kubectl`.

## Step 5: Create a Managed Node Group

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --nodegroup-name "$NODE_GROUP_NAME" \
  --subnets "$SUBNET1" "$SUBNET2" \
  --node-role "$NODE_ROLE_ARN" \
  --scaling-config minSize=1,maxSize=4,desiredSize=$NODE_COUNT \
  --instance-types "$NODE_TYPE" \
  --ami-type AL2_x86_64
```

> The node group is launched in the same subnets. The script waits until the group is fully active before proceeding.

### Final Output

```bash
kubectl get nodes
```

> Confirms that the EKS cluster is fully operational and displays the active nodes.
