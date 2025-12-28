#!/usr/bin/env bash
set -euo pipefail

############################################
# Lambda Starter + Fargate Spot Worker Deployment
# Reliable on-demand architecture: Starter checks queue, Worker owns message deletion
#
# Usage:
#   Basic (creates new buckets):
#     ./deploy.sh
#
#   Use existing buckets:
#     REGION=eu-west-1 SRC_BUCKET=my-source-bucket DST_BUCKET=my-express-bucket ./deploy.sh
#
#   Use existing Express bucket with full name:
#     DST_BUCKET=my-express--euw1-az1--x-s3 ./deploy.sh
#
#   Set prefix filter:
#     PREFIX_FILTER="deepseek-v3.2/" ./deploy.sh
############################################

# Configuration: Set via environment variables or use defaults
REGION="${REGION:-eu-north-1}"

# Bucket names: use provided names or create new ones with timestamp
TIMESTAMP=$(date +%s)
SRC_BUCKET="${SRC_BUCKET:-s3sync-standard-${TIMESTAMP}}"
# S3 Express One Zone bucket - suffix will be auto-generated based on AZ if not provided
DST_BUCKET="${DST_BUCKET:-s3sync-express-${TIMESTAMP}}"
PREFIX_FILTER="${PREFIX_FILTER:-}"

STACK_TAG="s3-to-s3express-sync"
APP_NAME="s3-to-s3express-sync"
QUEUE_NAME="${APP_NAME}-q"
DLQ_NAME="${APP_NAME}-dlq"

# ECS Settings
CLUSTER_NAME="${APP_NAME}-cluster"
TASK_FAMILY="${APP_NAME}-task"
TASK_ROLE_NAME="${APP_NAME}-task-role"
EXEC_ROLE_NAME="${APP_NAME}-exec-role"
ECR_REPO_NAME="${APP_NAME}"
TASK_CPU="2048"                     # 2 vCPU for 64 concurrent threads + 5 Gbps bandwidth
TASK_MEMORY="4096"                  # 4GB for boto3[crt] + 50 connection pool + 64 threads
VISIBILITY_TIMEOUT=7200             # 2 hours for large files
EMPTY_POLLS_BEFORE_EXIT=3           # Exit after 3 consecutive empty polls
VISIBILITY_EXTEND_INTERVAL=300      # Extend visibility every 5 minutes

# Lambda Starter Settings
LAMBDA_POLL_RATE="1"  # minutes between checks (1-5 recommended)
LAMBDA_NAME="${APP_NAME}-starter"
LAMBDA_ROLE_NAME="${LAMBDA_NAME}-role"
MAX_WORKERS=5

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Deploying Lambda Starter + Fargate Spot Worker solution..."
echo "Architecture: S3 → SQS → Lambda (starter) → Fargate Spot (worker)"
echo ""

############################################
# 0) Create S3 buckets if they don't exist
############################################
echo "Checking/Creating S3 buckets..."

# Create standard bucket
if ! aws s3api head-bucket --bucket "$SRC_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating standard bucket: $SRC_BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$SRC_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$SRC_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "Standard bucket created: s3://$SRC_BUCKET"
else
  echo "Standard bucket already exists: s3://$SRC_BUCKET"
fi

# Create S3 Express One Zone bucket
# Get availability zone ID first to construct full bucket name
AZ_ID=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneId' --output text)
echo "Using Availability Zone: $AZ_ID"

# Check if DST_BUCKET already has the full S3 Express format (ends with --x-s3)
if [[ "$DST_BUCKET" == *"--x-s3" ]]; then
  # User provided full Express bucket name
  DST_BUCKET_FULL="$DST_BUCKET"
  echo "Using existing S3 Express bucket name: $DST_BUCKET_FULL"
else
  # Construct full S3 Express bucket name with AZ suffix
  DST_BUCKET_FULL="${DST_BUCKET}--${AZ_ID}--x-s3"
fi

if ! aws s3api head-bucket --bucket "$DST_BUCKET_FULL" --region "$REGION" 2>/dev/null; then
  echo "Creating S3 Express One Zone bucket: $DST_BUCKET_FULL"

  aws s3api create-bucket \
    --bucket "$DST_BUCKET_FULL" \
    --region "$REGION" \
    --create-bucket-configuration "{
      \"Location\": {
        \"Type\": \"AvailabilityZone\",
        \"Name\": \"${AZ_ID}\"
      },
      \"Bucket\": {
        \"DataRedundancy\": \"SingleAvailabilityZone\",
        \"Type\": \"Directory\"
      }
    }"
  echo "S3 Express bucket created: s3://$DST_BUCKET_FULL"
else
  echo "S3 Express bucket already exists: s3://$DST_BUCKET_FULL"
fi

# Update DST_BUCKET to use full name for rest of script
DST_BUCKET="$DST_BUCKET_FULL"

############################################
# 1) Create or get existing SQS queue
############################################
echo "Checking/Creating SQS queues..."

# Create DLQ first
set +e
DLQ_URL=$(aws sqs get-queue-url --region "$REGION" --queue-name "$DLQ_NAME" --query 'QueueUrl' --output text 2>/dev/null)
set -e

if [ -z "$DLQ_URL" ] || [ "$DLQ_URL" = "None" ]; then
  echo "Creating DLQ: $DLQ_NAME"
  DLQ_URL=$(aws sqs create-queue \
    --region "$REGION" \
    --queue-name "$DLQ_NAME" \
    --attributes '{
      "MessageRetentionPeriod": "1209600"
    }' \
    --tags Project="$STACK_TAG" \
    --query 'QueueUrl' --output text)
  echo "DLQ created: $DLQ_URL"
else
  echo "DLQ already exists: $DLQ_URL"
fi

DLQ_ARN=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$DLQ_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# Create main queue
set +e
MAIN_URL=$(aws sqs get-queue-url --region "$REGION" --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null)
set -e

if [ -z "$MAIN_URL" ] || [ "$MAIN_URL" = "None" ]; then
  echo "Creating main queue: $QUEUE_NAME"
  MAIN_URL=$(aws sqs create-queue \
    --region "$REGION" \
    --queue-name "$QUEUE_NAME" \
    --attributes "{
      \"VisibilityTimeout\": \"${VISIBILITY_TIMEOUT}\",
      \"ReceiveMessageWaitTimeSeconds\": \"20\",
      \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":3}\"
    }" \
    --tags Project="$STACK_TAG" \
    --query 'QueueUrl' --output text)
  echo "Main queue created: $MAIN_URL"
else
  echo "Main queue already exists: $MAIN_URL"
fi

MAIN_ARN=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$MAIN_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# Allow S3 to send messages to SQS (must be set before notification configuration)
echo "Setting SQS policy to allow S3 events..."
cat > /tmp/sqs-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "s3.amazonaws.com"
      },
      "Action": "sqs:SendMessage",
      "Resource": "${MAIN_ARN}",
      "Condition": {
        "ArnLike": {
          "aws:SourceArn": "arn:aws:s3:::${SRC_BUCKET}"
        }
      }
    }
  ]
}
EOF

POLICY_JSON=$(cat /tmp/sqs-policy.json | jq -c . | sed 's/"/\\"/g')
cat > /tmp/sqs-attributes.json <<EOF
{
  "Policy": "${POLICY_JSON}"
}
EOF

aws sqs set-queue-attributes \
  --region "$REGION" \
  --queue-url "$MAIN_URL" \
  --attributes file:///tmp/sqs-attributes.json

# Configure S3 event notification
echo "Configuring S3 event notification..."
cat > /tmp/s3-notification.json <<EOF
{
  "QueueConfigurations": [
    {
      "QueueArn": "${MAIN_ARN}",
      "Events": ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket "$SRC_BUCKET" \
  --notification-configuration file:///tmp/s3-notification.json

echo "SQS Queue: $MAIN_ARN"

############################################
# 2) Create or get existing ECS resources
############################################
echo "Checking/Creating ECS cluster..."

# Create ECS cluster if not exists
set +e
aws ecs describe-clusters --region "$REGION" --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME"
CLUSTER_EXISTS=$?
set -e

if [ $CLUSTER_EXISTS -ne 0 ]; then
  echo "Creating ECS cluster: $CLUSTER_NAME"
  aws ecs create-cluster \
    --region "$REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 \
    --tags key=Project,value="$STACK_TAG" >/dev/null
  echo "ECS cluster created"
else
  echo "ECS cluster already exists: $CLUSTER_NAME"
  # Ensure cluster has Fargate Spot capacity provider
  aws ecs put-cluster-capacity-providers \
    --cluster "$CLUSTER_NAME" \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 \
    --region "$REGION" >/dev/null 2>&1 || true
fi

echo "Fargate Spot enabled on cluster"

# Create ECR repository if not exists
echo "Checking/Creating ECR repository..."
set +e
aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1
ECR_EXISTS=$?
set -e

if [ $ECR_EXISTS -ne 0 ]; then
  echo "Creating ECR repository: $ECR_REPO_NAME"
  aws ecr create-repository \
    --region "$REGION" \
    --repository-name "$ECR_REPO_NAME" \
    --tags Key=Project,Value="$STACK_TAG" >/dev/null
  echo "ECR repository created"
else
  echo "ECR repository already exists: $ECR_REPO_NAME"
fi

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

############################################
# 3) Rebuild Docker image with improved worker
############################################
echo "Building Docker image with improved worker..."
newgrp docker <<EOCMD
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null

docker build -t "${ECR_REPO_NAME}:latest" . -q
docker tag "${ECR_REPO_NAME}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest" | grep -E "(digest|latest)"
EOCMD

IMAGE_DIGEST=$(aws ecr describe-images --region "$REGION" --repository-name "$ECR_REPO_NAME" --image-ids imageTag=latest --query 'imageDetails[0].imageDigest' --output text)
IMAGE_URI="${ECR_URI}@${IMAGE_DIGEST}"
echo "Image: $IMAGE_URI"

############################################
# 4) Create IAM roles for ECS task
############################################
echo "Checking/Creating IAM roles..."

# Task Role (for S3 and SQS access)
set +e
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
set -e

if [ -z "$TASK_ROLE_ARN" ] || [ "$TASK_ROLE_ARN" = "None" ]; then
  echo "Creating task role: $TASK_ROLE_NAME"

  cat > /tmp/ecs-task-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  TASK_ROLE_ARN=$(aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ecs-task-trust.json \
    --tags Key=Project,Value="$STACK_TAG" \
    --query 'Role.Arn' --output text)

  echo "Task role created: $TASK_ROLE_ARN"
else
  echo "Task role already exists: $TASK_ROLE_ARN"
fi

# Always update task role policy (even if role exists) to reflect current bucket names
echo "Updating task role policy..."
cat > /tmp/task-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:HeadObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${SRC_BUCKET}",
        "arn:aws:s3:::${SRC_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3express:CreateSession"
      ],
      "Resource": "arn:aws:s3express:${REGION}:${ACCOUNT_ID}:bucket/${DST_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3express:${REGION}:${ACCOUNT_ID}:bucket/${DST_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": "${MAIN_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-name "${TASK_ROLE_NAME}-inline" \
  --policy-document file:///tmp/task-policy.json

# Execution Role (for ECR and CloudWatch Logs)
set +e
EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
set -e

if [ -z "$EXEC_ROLE_ARN" ] || [ "$EXEC_ROLE_ARN" = "None" ]; then
  echo "Creating execution role: $EXEC_ROLE_NAME"

  EXEC_ROLE_ARN=$(aws iam create-role \
    --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ecs-task-trust.json \
    --tags Key=Project,Value="$STACK_TAG" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$EXEC_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

  # Add CloudWatch Logs permissions for auto-creating log groups
  cat > /tmp/exec-logs-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

  aws iam put-role-policy \
    --role-name "$EXEC_ROLE_NAME" \
    --policy-name "logs-policy" \
    --policy-document file:///tmp/exec-logs-policy.json

  echo "Execution role created: $EXEC_ROLE_ARN"
else
  echo "Execution role already exists: $EXEC_ROLE_ARN"

  # Ensure logs policy exists on existing role
  cat > /tmp/exec-logs-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

  aws iam put-role-policy \
    --role-name "$EXEC_ROLE_NAME" \
    --policy-name "logs-policy" \
    --policy-document file:///tmp/exec-logs-policy.json 2>/dev/null || true
fi

echo "Waiting for IAM propagation..."
sleep 10

############################################
# 5) Update task definition for Fargate Spot
############################################
echo "Creating task definition for Fargate Spot..."

cat > /tmp/task-definition.json <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${TASK_CPU}",
  "memory": "${TASK_MEMORY}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "containerDefinitions": [
    {
      "name": "worker",
      "image": "${IMAGE_URI}",
      "essential": true,
      "environment": [
        {"name": "REGION", "value": "${REGION}"},
        {"name": "SRC_BUCKET", "value": "${SRC_BUCKET}"},
        {"name": "DST_BUCKET", "value": "${DST_BUCKET}"},
        {"name": "QUEUE_URL", "value": "${MAIN_URL}"},
        {"name": "PREFIX_FILTER", "value": "${PREFIX_FILTER}"},
        {"name": "VISIBILITY_TIMEOUT", "value": "${VISIBILITY_TIMEOUT}"},
        {"name": "WAIT_TIME_SECONDS", "value": "20"},
        {"name": "EMPTY_POLLS_BEFORE_EXIT", "value": "${EMPTY_POLLS_BEFORE_EXIT}"},
        {"name": "VISIBILITY_EXTEND_INTERVAL", "value": "${VISIBILITY_EXTEND_INTERVAL}"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${TASK_FAMILY}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "worker",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
EOF

TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" --cli-input-json file:///tmp/task-definition.json --query 'taskDefinition.taskDefinitionArn' --output text)
echo "Task definition: $TASK_DEF_ARN"

############################################
# 6) Get or create VPC and Subnets for Lambda to use
############################################
echo "Checking/Creating VPC configuration..."

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "No default VPC found, creating one..."
  VPC_ID=$(aws ec2 create-default-vpc --region "$REGION" --query 'Vpc.VpcId' --output text)
  echo "Default VPC created: $VPC_ID"
  # Wait for VPC to be ready
  sleep 5
else
  echo "Default VPC found: $VPC_ID"
fi

SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

if [ -z "$SUBNET_IDS" ]; then
  echo "ERROR: No subnets found in VPC $VPC_ID"
  exit 1
fi

echo "Using subnets: $SUBNET_IDS"

############################################
# 6.5) Create S3 VPC Endpoint (if not exists)
############################################
echo "Checking/Creating S3 VPC Endpoint..."

# Get route tables
ROUTE_TABLES=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[*].RouteTableId' \
  --output text)

# Check if S3 VPC Endpoint already exists
EXISTING_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$REGION.s3" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING_ENDPOINT" != "None" ] && [ -n "$EXISTING_ENDPOINT" ]; then
  echo "S3 VPC Endpoint already exists: $EXISTING_ENDPOINT"
else
  echo "Creating S3 VPC Endpoint (Gateway type)..."
  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --service-name "com.amazonaws.$REGION.s3" \
    --route-table-ids $ROUTE_TABLES \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text)
  echo "S3 VPC Endpoint created: $ENDPOINT_ID"
fi

############################################
# 7) Create Lambda Starter IAM Role
############################################
echo "Checking/Creating Lambda Starter IAM role..."

cat > /tmp/lambda-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

LAMBDA_ROLE_ARN=$(aws iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document file:///tmp/lambda-trust.json \
  --tags Key=Project,Value="$STACK_TAG" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)

# Always update Lambda role policy to reflect current resources
echo "Updating Lambda Starter role policy..."
cat > /tmp/lambda-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SqsRead",
      "Effect": "Allow",
      "Action": [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ],
      "Resource": "${MAIN_ARN}"
    },
    {
      "Sid": "EcsRunTask",
      "Effect": "Allow",
      "Action": [
        "ecs:RunTask",
        "ecs:ListTasks",
        "ecs:DescribeTasks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "${TASK_ROLE_ARN}",
        "${EXEC_ROLE_ARN}"
      ]
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${LAMBDA_NAME}:*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "${LAMBDA_ROLE_NAME}-inline" \
  --policy-document file:///tmp/lambda-policy.json

echo "Waiting for IAM propagation..."
sleep 10

############################################
# 8) Create or Update Lambda Starter
############################################
echo "Creating Lambda Starter function..."

# Create deployment package
cd /tmp
rm -f starter.zip
cat > /tmp/starter-lambda.py <<'EOPY'
import os, boto3

REGION = os.environ["REGION"]
QUEUE_URL = os.environ["QUEUE_URL"]
CLUSTER = os.environ["CLUSTER"]
TASK_DEFINITION = os.environ["TASK_DEFINITION"]
SUBNETS = os.environ["SUBNETS"].split(",")
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "2"))

sqs = boto3.client("sqs", region_name=REGION)
ecs = boto3.client("ecs", region_name=REGION)

def handler(event, context):
    attrs = sqs.get_queue_attributes(
        QueueUrl=QUEUE_URL,
        AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )["Attributes"]
    queue_depth = int(attrs.get("ApproximateNumberOfMessages", 0)) + int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0))

    running = len(ecs.list_tasks(cluster=CLUSTER, desiredStatus="RUNNING").get("taskArns", []))
    pending = len(ecs.list_tasks(cluster=CLUSTER, desiredStatus="PENDING").get("taskArns", []))
    running_tasks = running + pending

    print(f"Queue: {queue_depth} messages, Tasks: {running_tasks}/{MAX_WORKERS}")

    if queue_depth == 0:
        return {"statusCode": 200, "body": "No messages"}
    if running_tasks >= MAX_WORKERS:
        return {"statusCode": 200, "body": f"At capacity: {running_tasks}/{MAX_WORKERS}"}

    tasks_needed = min(MAX_WORKERS - running_tasks, queue_depth)

    started = []
    for i in range(tasks_needed):
        try:
            resp = ecs.run_task(
                cluster=CLUSTER,
                taskDefinition=TASK_DEFINITION,
                capacityProviderStrategy=[
                    {"capacityProvider": "FARGATE_SPOT", "weight": 4, "base": 0},
                    {"capacityProvider": "FARGATE", "weight": 1, "base": 0}
                ],
                networkConfiguration={
                    "awsvpcConfiguration": {
                        "subnets": SUBNETS,
                        "assignPublicIp": "ENABLED"
                    }
                },
                count=1
            )
            if resp.get("tasks"):
                started.append(resp["tasks"][0]["taskArn"])
                print(f"  Started: {resp['tasks'][0]['taskArn'].split('/')[-1]}")
        except Exception as e:
            print(f"  Failed: {e}")
            break

    return {"statusCode": 200, "body": f"Started {len(started)} tasks", "tasksStarted": len(started)}
EOPY

zip -q starter.zip starter-lambda.py
cd - >/dev/null

# Create or update Lambda
set +e
aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1
LAMBDA_EXISTS=$?
set -e

cat > /tmp/lambda-env.json <<EOF
{
  "Variables": {
    "REGION": "${REGION}",
    "QUEUE_URL": "${MAIN_URL}",
    "CLUSTER": "${CLUSTER_NAME}",
    "TASK_DEFINITION": "${TASK_DEF_ARN}",
    "SUBNETS": "${SUBNET_IDS}",
    "MAX_WORKERS": "${MAX_WORKERS}"
  }
}
EOF

if [ $LAMBDA_EXISTS -ne 0 ]; then
  echo "Creating new Lambda function..."
  aws lambda create-function \
    --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler starter-lambda.handler \
    --zip-file fileb:///tmp/starter.zip \
    --timeout 60 \
    --memory-size 128 \
    --environment file:///tmp/lambda-env.json \
    --tags Project="$STACK_TAG" >/dev/null
else
  echo "Updating existing Lambda function..."
  aws lambda update-function-code \
    --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb:///tmp/starter.zip >/dev/null

  aws lambda update-function-configuration \
    --region "$REGION" \
    --function-name "$LAMBDA_NAME" \
    --environment file:///tmp/lambda-env.json >/dev/null
fi

############################################
# 9) Create EventBridge Schedule Rule
############################################
echo "Creating EventBridge schedule rule..."
RULE_NAME="${APP_NAME}-starter-rule"

aws events put-rule \
  --region "$REGION" \
  --name "$RULE_NAME" \
  --schedule-expression "rate(${LAMBDA_POLL_RATE} minute)" \
  --state ENABLED \
  --description "Trigger Lambda Starter to check SQS and start Fargate Spot tasks" >/dev/null

LAMBDA_ARN=$(aws lambda get-function --region "$REGION" --function-name "$LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission \
  --region "$REGION" \
  --function-name "$LAMBDA_NAME" \
  --statement-id AllowEventBridge \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}" 2>/dev/null || true

aws events put-targets \
  --region "$REGION" \
  --rule "$RULE_NAME" \
  --targets "Id=1,Arn=${LAMBDA_ARN}" >/dev/null

echo ""
echo "✅ Lambda Starter + Fargate Spot deployment complete!"
echo ""
echo "Architecture:"
echo "  S3 Event → SQS Queue"
echo "  Lambda Starter (every ${LAMBDA_POLL_RATE} min) → checks queue → starts Fargate Spot tasks"
echo "  Fargate Spot Worker → pulls SQS → processes → deletes message → exits when queue empty"
echo ""
echo "Key features:"
echo "  ✅ Worker owns message deletion (reliable, no data loss)"
echo "  ✅ SIGTERM handling (Spot interruption graceful shutdown)"
echo "  ✅ Visibility timeout extension (for large files)"
echo "  ✅ HeadObject verification (idempotency)"
echo "  ✅ Exit after ${EMPTY_POLLS_BEFORE_EXIT} empty polls"
echo "  ✅ Fargate Spot (80% priority) + Fargate fallback (20%)"
echo ""
echo "Source bucket: s3://${SRC_BUCKET}"
echo "Target bucket: s3://${DST_BUCKET}"
echo "Max workers: ${MAX_WORKERS}"
echo "Check interval: ${LAMBDA_POLL_RATE} minute(s)"
echo ""
echo "Monitor:"
echo "  Lambda: aws logs tail /aws/lambda/${LAMBDA_NAME} --follow --region ${REGION}"
echo "  Worker: aws logs tail /ecs/${TASK_FAMILY} --follow --region ${REGION}"
echo ""
echo "Test: Upload a file and watch the logs!"
