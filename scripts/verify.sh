#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"

source "${SCRIPT_DIR}/common.sh"

REGION=$(yq '.aws.region' "$CONFIG_FILE")
VPC_ID=$(yq '.phase1.vpc.vpc_id' "$CONFIG_FILE")
STANDARD_BUCKET=$(yq '.phase1.standard_bucket.name' "$CONFIG_FILE")
EXPRESS_BUCKET=$(yq '.phase2.express_bucket.name' "$CONFIG_FILE")
LAMBDA_FUNCTION_NAME=$(yq '.phase2.lambda.function_name' "$CONFIG_FILE")

log_info "Verifying S3 Sync setup..."
echo ""

# Verification functions
verify_phase1() {
    log_info "=== Phase 1 Verification ==="

    # Check S3 Interface Endpoint
    ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${REGION}.s3" "Name=vpc-endpoint-type,Values=Interface" \
        --query 'VpcEndpoints[0].VpcEndpointId' \
        --output text 2>/dev/null || echo "")

    if [ "$ENDPOINT_ID" != "None" ] && [ -n "$ENDPOINT_ID" ]; then
        ENDPOINT_STATE=$(aws ec2 describe-vpc-endpoints \
            --region "$REGION" \
            --vpc-endpoint-ids "$ENDPOINT_ID" \
            --query 'VpcEndpoints[0].State' \
            --output text)

        if [ "$ENDPOINT_STATE" = "available" ]; then
            log_info "✓ S3 Interface Endpoint: $ENDPOINT_ID (available)"
        else
            log_warn "✗ S3 Interface Endpoint: $ENDPOINT_ID (state: $ENDPOINT_STATE)"
        fi
    else
        log_error "✗ S3 Interface Endpoint: NOT FOUND"
    fi

    # Check Route53 Resolver Endpoint
    RESOLVER_NAME=$(yq '.phase1.resolver.name' "$CONFIG_FILE")
    RESOLVER_ID=$(aws route53resolver list-resolver-endpoints \
        --region "$REGION" \
        --query "ResolverEndpoints[?Name=='$RESOLVER_NAME'].Id | [0]" \
        --output text 2>/dev/null || echo "")

    if [ "$RESOLVER_ID" != "None" ] && [ -n "$RESOLVER_ID" ]; then
        RESOLVER_STATUS=$(aws route53resolver get-resolver-endpoint \
            --region "$REGION" \
            --resolver-endpoint-id "$RESOLVER_ID" \
            --query 'ResolverEndpoint.Status' \
            --output text)

        if [ "$RESOLVER_STATUS" = "OPERATIONAL" ]; then
            RESOLVER_IPS=$(aws route53resolver get-resolver-endpoint \
                --region "$REGION" \
                --resolver-endpoint-id "$RESOLVER_ID" \
                --query 'ResolverEndpoint.IpAddresses[*].Ip' \
                --output text)
            log_info "✓ Route53 Resolver Endpoint: $RESOLVER_ID (operational)"
            log_info "  Resolver IPs: $RESOLVER_IPS"
        else
            log_warn "✗ Route53 Resolver Endpoint: $RESOLVER_ID (status: $RESOLVER_STATUS)"
        fi
    else
        log_error "✗ Route53 Resolver Endpoint: NOT FOUND"
    fi

    # Check Standard S3 Bucket
    if aws s3api head-bucket --bucket "$STANDARD_BUCKET" --region "$REGION" 2>/dev/null; then
        log_info "✓ S3 Standard Bucket: $STANDARD_BUCKET (exists)"

        VERSIONING=$(aws s3api get-bucket-versioning \
            --bucket "$STANDARD_BUCKET" \
            --region "$REGION" \
            --query 'Status' \
            --output text 2>/dev/null || echo "None")

        if [ "$VERSIONING" = "Enabled" ]; then
            log_info "  Versioning: Enabled"
        else
            log_warn "  Versioning: $VERSIONING"
        fi
    else
        log_error "✗ S3 Standard Bucket: $STANDARD_BUCKET (NOT FOUND)"
    fi

    echo ""
}

verify_phase2() {
    log_info "=== Phase 2 Verification ==="

    # Check Lambda function
    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$REGION" &>/dev/null; then
        LAMBDA_STATE=$(aws lambda get-function \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --query 'Configuration.State' \
            --output text)

        if [ "$LAMBDA_STATE" = "Active" ]; then
            log_info "✓ Lambda Function: $LAMBDA_FUNCTION_NAME (active)"

            LAST_MODIFIED=$(aws lambda get-function \
                --region "$REGION" \
                --function-name "$LAMBDA_FUNCTION_NAME" \
                --query 'Configuration.LastModified' \
                --output text)
            log_info "  Last Modified: $LAST_MODIFIED"

            RUNTIME=$(aws lambda get-function \
                --region "$REGION" \
                --function-name "$LAMBDA_FUNCTION_NAME" \
                --query 'Configuration.Runtime' \
                --output text)
            log_info "  Runtime: $RUNTIME"
        else
            log_warn "✗ Lambda Function: $LAMBDA_FUNCTION_NAME (state: $LAMBDA_STATE)"
        fi
    else
        log_error "✗ Lambda Function: $LAMBDA_FUNCTION_NAME (NOT FOUND)"
    fi

    # Check S3 event notification
    NOTIFICATION=$(aws s3api get-bucket-notification-configuration \
        --bucket "$STANDARD_BUCKET" \
        --region "$REGION" 2>/dev/null || echo "{}")

    LAMBDA_CONFIGS=$(echo "$NOTIFICATION" | jq -r '.LambdaFunctionConfigurations | length' 2>/dev/null || echo "0")

    if [ "$LAMBDA_CONFIGS" -gt 0 ]; then
        log_info "✓ S3 Event Notification: Configured ($LAMBDA_CONFIGS configuration(s))"

        echo "$NOTIFICATION" | jq -r '.LambdaFunctionConfigurations[] | "  Event: \(.Events[0]), Prefix: \(.Filter.Key.FilterRules[] | select(.Name=="prefix") | .Value)"' 2>/dev/null || true
    else
        log_error "✗ S3 Event Notification: NOT CONFIGURED"
    fi

    # Check IAM Role
    LAMBDA_ROLE_NAME=$(yq '.iam.lambda_role_name' "$CONFIG_FILE")
    if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
        log_info "✓ IAM Role: $LAMBDA_ROLE_NAME (exists)"

        ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
            --role-name "$LAMBDA_ROLE_NAME" \
            --query 'AttachedPolicies[*].PolicyName' \
            --output text)
        log_info "  Attached Policies: $ATTACHED_POLICIES"
    else
        log_error "✗ IAM Role: $LAMBDA_ROLE_NAME (NOT FOUND)"
    fi

    echo ""
}

test_end_to_end() {
    log_info "=== End-to-End Test ==="

    INCOMING_PREFIX=$(yq '.phase1.standard_bucket.incoming_prefix' "$CONFIG_FILE")
    TEST_FILE="/tmp/s3sync-test-$(date +%s).txt"

    echo "Test file created at $(date)" > "$TEST_FILE"

    log_info "Uploading test file to s3://${STANDARD_BUCKET}/${INCOMING_PREFIX}"

    if aws s3 cp "$TEST_FILE" "s3://${STANDARD_BUCKET}/${INCOMING_PREFIX}" --region "$REGION" 2>/dev/null; then
        log_info "✓ Test file uploaded successfully"

        log_info "Waiting 5 seconds for Lambda to process..."
        sleep 5

        log_info "Checking CloudWatch Logs for Lambda execution..."
        LOG_STREAMS=$(aws logs describe-log-streams \
            --log-group-name "/aws/lambda/${LAMBDA_FUNCTION_NAME}" \
            --region "$REGION" \
            --order-by LastEventTime \
            --descending \
            --max-items 1 \
            --query 'logStreams[0].logStreamName' \
            --output text 2>/dev/null || echo "")

        if [ -n "$LOG_STREAMS" ] && [ "$LOG_STREAMS" != "None" ]; then
            log_info "✓ Recent Lambda execution found"
            log_info "  View logs: aws logs tail /aws/lambda/${LAMBDA_FUNCTION_NAME} --region ${REGION} --follow"
        else
            log_warn "✗ No recent Lambda execution found"
        fi

        rm -f "$TEST_FILE"
    else
        log_error "✗ Failed to upload test file"
        rm -f "$TEST_FILE"
    fi

    echo ""
}

# Main execution
main() {
    verify_phase1
    verify_phase2

    echo ""
    read -p "Do you want to run an end-to-end test? (yes/no): " run_test

    if [ "$run_test" = "yes" ]; then
        test_end_to_end
    fi

    log_info "Verification completed"
    echo ""
    log_info "Summary:"
    log_info "- Phase 1: Network and S3 Interface Endpoint setup"
    log_info "- Phase 2: Lambda sync to S3 Express One Zone"
    echo ""
    log_info "For detailed logs, check:"
    log_info "  CloudWatch Logs: /aws/lambda/${LAMBDA_FUNCTION_NAME}"
    log_info "  S3 Standard Bucket: s3://${STANDARD_BUCKET}"
    log_info "  S3 Express Bucket: s3://${EXPRESS_BUCKET}"
}

main
