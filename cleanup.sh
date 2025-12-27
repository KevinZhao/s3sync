#!/usr/bin/env bash
set -euo pipefail

############################################
# Complete Cleanup Script
############################################
REGION="eu-north-1"
APP_NAME="s3-to-s3express-sync"
PIPE_NAME="${APP_NAME}-pipe"
PIPE_ROLE_NAME="${PIPE_NAME}-role"
CLUSTER_NAME="${APP_NAME}-cluster"
TASK_FAMILY="${APP_NAME}-task"
TASK_ROLE_NAME="${APP_NAME}-task-role"
EXEC_ROLE_NAME="${APP_NAME}-exec-role"
ECR_REPO_NAME="${APP_NAME}"
QUEUE_NAME="${APP_NAME}-q"
DLQ_NAME="${APP_NAME}-dlq"
SRC_BUCKET="s3sync-standard-stockholm-1766755639"

echo "Cleaning up all resources..."
echo ""

############################################
# 1) Stop and delete EventBridge Pipe
############################################
echo "Deleting EventBridge Pipe..."
set +e
aws pipes stop-pipe --name "$PIPE_NAME" --region "$REGION" 2>/dev/null
sleep 5
aws pipes delete-pipe --name "$PIPE_NAME" --region "$REGION" 2>/dev/null
set -e

############################################
# 2) Delete Pipe IAM Role
############################################
echo "Deleting Pipe IAM role..."
set +e
aws iam delete-role-policy \
  --role-name "$PIPE_ROLE_NAME" \
  --policy-name "${PIPE_ROLE_NAME}-inline" 2>/dev/null
aws iam delete-role --role-name "$PIPE_ROLE_NAME" 2>/dev/null
set -e

############################################
# 3) Delete ECS Service and Tasks
############################################
echo "Deleting ECS service..."
set +e
aws ecs update-service \
  --region "$REGION" \
  --cluster "$CLUSTER_NAME" \
  --service "${APP_NAME}-service" \
  --desired-count 0 2>/dev/null

sleep 10

aws ecs delete-service \
  --region "$REGION" \
  --cluster "$CLUSTER_NAME" \
  --service "${APP_NAME}-service" \
  --force 2>/dev/null

sleep 5

echo "Deleting ECS cluster..."
aws ecs delete-cluster \
  --region "$REGION" \
  --cluster "$CLUSTER_NAME" 2>/dev/null
set -e

############################################
# 4) Delete Task IAM Roles
############################################
echo "Deleting IAM roles..."
set +e
aws iam delete-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-name "${TASK_ROLE_NAME}-inline" 2>/dev/null
aws iam delete-role --role-name "$TASK_ROLE_NAME" 2>/dev/null

aws iam detach-role-policy \
  --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null
aws iam delete-role --role-name "$EXEC_ROLE_NAME" 2>/dev/null
set -e

############################################
# 5) Delete ECR Repository
############################################
echo "Deleting ECR repository..."
set +e
aws ecr delete-repository \
  --region "$REGION" \
  --repository-name "$ECR_REPO_NAME" \
  --force 2>/dev/null
set -e

############################################
# 6) Remove S3 Event Notification
############################################
echo "Removing S3 event notifications..."
set +e
aws s3api put-bucket-notification-configuration \
  --region "$REGION" \
  --bucket "$SRC_BUCKET" \
  --notification-configuration '{}' 2>/dev/null
set -e

############################################
# 7) Delete SQS Queues
############################################
echo "Deleting SQS queues..."
set +e
MAIN_URL=$(aws sqs get-queue-url --region "$REGION" --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null)
if [ -n "$MAIN_URL" ] && [ "$MAIN_URL" != "None" ]; then
  aws sqs delete-queue --region "$REGION" --queue-url "$MAIN_URL" 2>/dev/null
fi

DLQ_URL=$(aws sqs get-queue-url --region "$REGION" --queue-name "$DLQ_NAME" --query 'QueueUrl' --output text 2>/dev/null)
if [ -n "$DLQ_URL" ] && [ "$DLQ_URL" != "None" ]; then
  aws sqs delete-queue --region "$REGION" --queue-url "$DLQ_URL" 2>/dev/null
fi
set -e

############################################
# 8) Delete CloudWatch Logs
############################################
echo "Deleting CloudWatch log groups..."
set +e
aws logs delete-log-group \
  --region "$REGION" \
  --log-group-name "/ecs/${TASK_FAMILY}" 2>/dev/null
set -e

echo ""
echo "✅ Complete cleanup finished!"
echo ""
echo "Note: S3 buckets are preserved. To delete them:"
echo "  aws s3 rb s3://$SRC_BUCKET --force --region $REGION"
echo "  aws s3 rb s3://your-express-bucket--eun1-az1--x-s3 --force --region $REGION"
