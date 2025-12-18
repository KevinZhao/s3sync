#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"

source "${SCRIPT_DIR}/common.sh"

# Load configuration
REGION=$(yq '.aws.region' "$CONFIG_FILE")
STANDARD_BUCKET=$(yq '.phase1.standard_bucket.name' "$CONFIG_FILE")
INCOMING_PREFIX=$(yq '.phase1.standard_bucket.incoming_prefix' "$CONFIG_FILE")
EXPRESS_BUCKET=$(yq '.phase2.express_bucket.name' "$CONFIG_FILE")
INGEST_PREFIX=$(yq '.phase2.express_bucket.ingest_prefix' "$CONFIG_FILE")
LAMBDA_FUNCTION_NAME=$(yq '.phase2.lambda.function_name' "$CONFIG_FILE")
LAMBDA_TIMEOUT=$(yq '.phase2.lambda.timeout' "$CONFIG_FILE")
LAMBDA_MEMORY=$(yq '.phase2.lambda.memory_size' "$CONFIG_FILE")
LAMBDA_RUNTIME=$(yq '.phase2.lambda.runtime' "$CONFIG_FILE")
LAMBDA_SUBNET_IDS=($(yq '.phase2.lambda_vpc.subnet_ids[]' "$CONFIG_FILE"))
LAMBDA_ROLE_NAME=$(yq '.iam.lambda_role_name' "$CONFIG_FILE")

log_info "Phase 2: Setting up Lambda sync to S3 Express One Zone"

# Step 1: Verify Express bucket exists
verify_express_bucket() {
    log_info "Verifying S3 Express bucket exists: $EXPRESS_BUCKET"

    # Try to access the bucket
    if aws s3api head-bucket --bucket "$EXPRESS_BUCKET" --region "$REGION" 2>/dev/null; then
        log_info "S3 Express bucket verified: $EXPRESS_BUCKET"
    else
        log_error "S3 Express bucket does not exist: $EXPRESS_BUCKET"
        log_error "Please create the Express One Zone bucket manually before running Phase 2"
        log_error "Express buckets must be created with specific AZ configuration"
        exit 1
    fi

    # Verify bucket type (Express buckets have special naming)
    if [[ ! "$EXPRESS_BUCKET" =~ --[a-z0-9]+-az[0-9]+--x-s3$ ]]; then
        log_warn "Warning: Bucket name doesn't match Express One Zone naming pattern"
        log_warn "Expected format: bucket-name--azid--x-s3"
        log_warn "Example: my-bucket--eun1-az1--x-s3"
    fi
}

# Step 2: Create IAM Role for Lambda
create_lambda_role() {
    log_info "Creating IAM Role for Lambda..."

    # Check if role exists
    if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
        log_info "IAM Role already exists: $LAMBDA_ROLE_NAME"
        ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)
    else
        # Create trust policy
        TRUST_POLICY=$(cat <<EOF
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
)

        ROLE_ARN=$(aws iam create-role \
            --role-name "$LAMBDA_ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --query 'Role.Arn' \
            --output text)
        log_info "Created IAM Role: $ROLE_ARN"

        # Check and attach AWS managed policy for VPC execution
        VPC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
        VPC_ATTACHED=$(aws iam list-attached-role-policies \
            --role-name "$LAMBDA_ROLE_NAME" \
            --query "AttachedPolicies[?PolicyArn=='$VPC_POLICY_ARN'].PolicyArn" \
            --output text 2>/dev/null || echo "")

        if [ -z "$VPC_ATTACHED" ]; then
            aws iam attach-role-policy \
                --role-name "$LAMBDA_ROLE_NAME" \
                --policy-arn "$VPC_POLICY_ARN"
            log_info "Attached AWSLambdaVPCAccessExecutionRole policy"
        else
            log_info "AWSLambdaVPCAccessExecutionRole already attached"
        fi

        # Create and attach custom policy for S3 access
        POLICY_NAME="${LAMBDA_ROLE_NAME}-S3Policy"
        POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${STANDARD_BUCKET}",
        "arn:aws:s3:::${STANDARD_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3express:CreateSession"
      ],
      "Resource": "arn:aws:s3express:${REGION}:*:bucket/${EXPRESS_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3express:*"
      ],
      "Resource": "arn:aws:s3express:${REGION}:*:bucket/${EXPRESS_BUCKET}/*"
    }
  ]
}
EOF
)

        # Check if policy exists
        POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn | [0]" --output text 2>/dev/null || echo "")

        if [ "$POLICY_ARN" = "None" ] || [ -z "$POLICY_ARN" ]; then
            POLICY_ARN=$(aws iam create-policy \
                --policy-name "$POLICY_NAME" \
                --policy-document "$POLICY_DOC" \
                --query 'Policy.Arn' \
                --output text)
            log_info "Created custom S3 policy: $POLICY_ARN"
        else
            log_info "Policy already exists: $POLICY_ARN"
        fi

        # Check if policy is already attached
        ATTACHED=$(aws iam list-attached-role-policies \
            --role-name "$LAMBDA_ROLE_NAME" \
            --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
            --output text 2>/dev/null || echo "")

        if [ -z "$ATTACHED" ]; then
            aws iam attach-role-policy \
                --role-name "$LAMBDA_ROLE_NAME" \
                --policy-arn "$POLICY_ARN"
            log_info "Attached custom S3 policy to role"
        else
            log_info "Policy already attached to role"
        fi

        # Wait for role to be ready
        log_info "Waiting for IAM role to propagate..."
        sleep 10
    fi

    echo "$ROLE_ARN"
}

# Step 3: Create Lambda deployment package
create_lambda_package() {
    log_info "Creating Lambda deployment package..."

    LAMBDA_DIR="${SCRIPT_DIR}/../lambda"
    mkdir -p "$LAMBDA_DIR"

    # Copy Lambda function code
    cp "${SCRIPT_DIR}/lambda_function.py" "$LAMBDA_DIR/"

    # Create zip package
    cd "$LAMBDA_DIR"
    zip -q lambda_function.zip lambda_function.py
    log_info "Lambda package created: ${LAMBDA_DIR}/lambda_function.zip"

    echo "${LAMBDA_DIR}/lambda_function.zip"
}

# Step 4: Get security group from VPC
get_lambda_security_group() {
    log_info "Getting security group for Lambda..."

    # Get VPC ID from subnet
    VPC_ID=$(aws ec2 describe-subnets \
        --region "$REGION" \
        --subnet-ids "${LAMBDA_SUBNET_IDS[0]}" \
        --query 'Subnets[0].VpcId' \
        --output text)

    # Check if Lambda SG exists, create if not
    SG_NAME="lambda-s3-sync-sg"
    SG_ID=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")

    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        SG_ID=$(aws ec2 create-security-group \
            --region "$REGION" \
            --group-name "$SG_NAME" \
            --description "Security group for Lambda S3 sync function" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)
        log_info "Created security group: $SG_ID"

        # Note: Default egress rule (all traffic to 0.0.0.0/0) is automatically created
        # No need to explicitly add HTTPS egress rule
    else
        log_info "Using existing security group: $SG_ID"
    fi

    echo "$SG_ID"
}

# Step 5: Create or update Lambda function
create_lambda_function() {
    local role_arn=$1
    local package_path=$2
    local sg_id=$3

    log_info "Creating Lambda function..."

    # Set environment variables for Lambda
    ENV_VARS="Variables={EXPRESS_BUCKET=${EXPRESS_BUCKET},INGEST_PREFIX=${INGEST_PREFIX}}"

    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$REGION" &>/dev/null; then
        log_info "Lambda function exists, updating code..."
        aws lambda update-function-code \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --zip-file "fileb://${package_path}" \
            --output text >/dev/null

        aws lambda update-function-configuration \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --timeout "$LAMBDA_TIMEOUT" \
            --memory-size "$LAMBDA_MEMORY" \
            --environment "$ENV_VARS" \
            --output text >/dev/null
        log_info "Lambda function updated"
    else
        aws lambda create-function \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$role_arn" \
            --handler "lambda_function.lambda_handler" \
            --zip-file "fileb://${package_path}" \
            --timeout "$LAMBDA_TIMEOUT" \
            --memory-size "$LAMBDA_MEMORY" \
            --environment "$ENV_VARS" \
            --vpc-config "SubnetIds=$(IFS=,; echo "${LAMBDA_SUBNET_IDS[*]}"),SecurityGroupIds=$sg_id" \
            --output text >/dev/null
        log_info "Lambda function created: $LAMBDA_FUNCTION_NAME"

        # Wait for function to be active
        log_info "Waiting for Lambda function to be active..."
        aws lambda wait function-active --region "$REGION" --function-name "$LAMBDA_FUNCTION_NAME"
    fi

    FUNCTION_ARN=$(aws lambda get-function \
        --region "$REGION" \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --query 'Configuration.FunctionArn' \
        --output text)

    echo "$FUNCTION_ARN"
}

# Step 6: Add Lambda permission for S3 to invoke
add_lambda_permission() {
    local function_arn=$1

    log_info "Adding S3 invoke permission to Lambda..."

    STATEMENT_ID="s3-invoke-lambda-${STANDARD_BUCKET}"

    # Check if permission already exists
    PERMISSION_EXISTS=$(aws lambda get-policy \
        --region "$REGION" \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --query 'Policy' \
        --output text 2>/dev/null | grep -o "\"Sid\":\"$STATEMENT_ID\"" || echo "")

    if [ -z "$PERMISSION_EXISTS" ]; then
        # Add permission
        aws lambda add-permission \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --statement-id "$STATEMENT_ID" \
            --action "lambda:InvokeFunction" \
            --principal s3.amazonaws.com \
            --source-arn "arn:aws:s3:::${STANDARD_BUCKET}" \
            --output text >/dev/null
        log_info "Lambda permission added"
    else
        log_info "Lambda permission already exists"
    fi
}

# Step 7: Configure S3 event notification
configure_s3_event() {
    local function_arn=$1

    log_info "Configuring S3 event notification..."

    # Check if notification already exists
    EXISTING_CONFIG=$(aws s3api get-bucket-notification-configuration \
        --region "$REGION" \
        --bucket "$STANDARD_BUCKET" 2>/dev/null || echo "")

    CONFIG_ID="s3-to-express-sync"

    if echo "$EXISTING_CONFIG" | grep -q "\"Id\": *\"$CONFIG_ID\"" 2>/dev/null; then
        log_info "S3 event notification already configured"

        # Check if function ARN matches
        EXISTING_ARN=$(echo "$EXISTING_CONFIG" | grep -A5 "\"Id\": *\"$CONFIG_ID\"" | grep "LambdaFunctionArn" | sed 's/.*: *"\([^"]*\)".*/\1/')
        if [ "$EXISTING_ARN" = "$function_arn" ]; then
            log_info "Event notification is up to date"
            return 0
        else
            log_info "Updating event notification with new function ARN"
        fi
    fi

    NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "${CONFIG_ID}",
      "LambdaFunctionArn": "${function_arn}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "prefix",
              "Value": "${INCOMING_PREFIX}"
            }
          ]
        }
      }
    }
  ]
}
EOF
)

    echo "$NOTIFICATION_CONFIG" > /tmp/s3-notification.json

    aws s3api put-bucket-notification-configuration \
        --region "$REGION" \
        --bucket "$STANDARD_BUCKET" \
        --notification-configuration "file:///tmp/s3-notification.json"

    rm /tmp/s3-notification.json

    log_info "S3 event notification configured"
}

# Main execution
main() {
    log_info "Starting Phase 2 setup..."

    verify_express_bucket
    ROLE_ARN=$(create_lambda_role)
    PACKAGE_PATH=$(create_lambda_package)
    SG_ID=$(get_lambda_security_group)
    FUNCTION_ARN=$(create_lambda_function "$ROLE_ARN" "$PACKAGE_PATH" "$SG_ID")
    add_lambda_permission "$FUNCTION_ARN"
    configure_s3_event "$FUNCTION_ARN"

    # Save output
    OUTPUT_FILE="${SCRIPT_DIR}/../phase2-output.json"
    cat > "$OUTPUT_FILE" << EOF
{
  "lambda_role_arn": "$ROLE_ARN",
  "lambda_function_arn": "$FUNCTION_ARN",
  "lambda_security_group_id": "$SG_ID"
}
EOF

    log_info "Phase 2 setup completed successfully!"
    log_info "Output saved to: $OUTPUT_FILE"
    echo ""
    log_warn "Next steps:"
    log_warn "1. Test the complete flow by uploading a file from JD Cloud:"
    log_warn "   aws s3 cp testfile s3://${STANDARD_BUCKET}/${INCOMING_PREFIX}"
    log_warn "2. Check CloudWatch Logs for Lambda execution:"
    log_warn "   aws logs tail /aws/lambda/${LAMBDA_FUNCTION_NAME} --follow"
    log_warn "3. Verify file appears in Express bucket:"
    log_warn "   aws s3 ls s3://${EXPRESS_BUCKET}/${INGEST_PREFIX}"
}

main
