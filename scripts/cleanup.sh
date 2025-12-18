#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"

source "${SCRIPT_DIR}/common.sh"

REGION=$(yq '.aws.region' "$CONFIG_FILE")
VPC_ID=$(yq '.phase1.vpc.vpc_id' "$CONFIG_FILE")
STANDARD_BUCKET=$(yq '.phase1.standard_bucket.name' "$CONFIG_FILE")
LAMBDA_FUNCTION_NAME=$(yq '.phase2.lambda.function_name' "$CONFIG_FILE")
LAMBDA_ROLE_NAME=$(yq '.iam.lambda_role_name' "$CONFIG_FILE")
RESOLVER_NAME=$(yq '.phase1.resolver.name' "$CONFIG_FILE")

log_warn "Starting cleanup process..."
log_warn "This will delete all resources created by the setup scripts"
echo ""

# Cleanup Phase 2 resources
cleanup_phase2() {
    log_info "=== Cleaning up Phase 2 resources ==="

    # Remove S3 event notification
    log_info "Removing S3 event notification..."
    aws s3api put-bucket-notification-configuration \
        --bucket "$STANDARD_BUCKET" \
        --region "$REGION" \
        --notification-configuration '{}' 2>/dev/null || log_warn "Failed to remove S3 event notification"

    # Delete Lambda function
    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$REGION" &>/dev/null; then
        log_info "Deleting Lambda function: $LAMBDA_FUNCTION_NAME"
        aws lambda delete-function \
            --region "$REGION" \
            --function-name "$LAMBDA_FUNCTION_NAME"
        log_info "Lambda function deleted"
    else
        log_info "Lambda function not found: $LAMBDA_FUNCTION_NAME"
    fi

    # Delete Lambda security group
    SG_NAME="lambda-s3-sync-sg"
    SG_ID=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")

    if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
        log_info "Deleting Lambda security group: $SG_ID"
        # Wait a bit for Lambda ENIs to be removed
        sleep 10
        aws ec2 delete-security-group \
            --region "$REGION" \
            --group-id "$SG_ID" 2>/dev/null || log_warn "Failed to delete security group (may have dependencies)"
    fi

    # Detach and delete IAM policies
    if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
        log_info "Cleaning up IAM role: $LAMBDA_ROLE_NAME"

        # List and detach all attached policies
        ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
            --role-name "$LAMBDA_ROLE_NAME" \
            --query 'AttachedPolicies[*].PolicyArn' \
            --output text)

        for policy_arn in $ATTACHED_POLICIES; do
            log_info "Detaching policy: $policy_arn"
            aws iam detach-role-policy \
                --role-name "$LAMBDA_ROLE_NAME" \
                --policy-arn "$policy_arn"

            # Delete custom policies (not AWS managed)
            if [[ "$policy_arn" != *":aws:policy/"* ]]; then
                log_info "Deleting custom policy: $policy_arn"
                aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || log_warn "Failed to delete policy"
            fi
        done

        # Delete role
        log_info "Deleting IAM role: $LAMBDA_ROLE_NAME"
        aws iam delete-role --role-name "$LAMBDA_ROLE_NAME"
        log_info "IAM role deleted"
    fi

    # Delete Lambda package
    if [ -d "${SCRIPT_DIR}/../lambda" ]; then
        log_info "Removing Lambda package directory"
        rm -rf "${SCRIPT_DIR}/../lambda"
    fi

    echo ""
}

# Cleanup Phase 1 resources
cleanup_phase1() {
    log_info "=== Cleaning up Phase 1 resources ==="

    # Delete Route53 Resolver Inbound Endpoint
    RESOLVER_ID=$(aws route53resolver list-resolver-endpoints \
        --region "$REGION" \
        --query "ResolverEndpoints[?Name=='$RESOLVER_NAME'].Id | [0]" \
        --output text 2>/dev/null || echo "")

    if [ "$RESOLVER_ID" != "None" ] && [ -n "$RESOLVER_ID" ]; then
        log_info "Deleting Route53 Resolver Inbound Endpoint: $RESOLVER_ID"

        # Get resolver security group before deletion
        RESOLVER_SG=$(aws route53resolver get-resolver-endpoint \
            --region "$REGION" \
            --resolver-endpoint-id "$RESOLVER_ID" \
            --query 'ResolverEndpoint.SecurityGroupIds[0]' \
            --output text 2>/dev/null || echo "")

        aws route53resolver delete-resolver-endpoint \
            --region "$REGION" \
            --resolver-endpoint-id "$RESOLVER_ID" >/dev/null

        log_info "Waiting for resolver endpoint to be deleted..."
        while true; do
            STATUS=$(aws route53resolver get-resolver-endpoint \
                --region "$REGION" \
                --resolver-endpoint-id "$RESOLVER_ID" \
                --query 'ResolverEndpoint.Status' \
                --output text 2>/dev/null || echo "DELETED")
            if [ "$STATUS" = "DELETED" ]; then
                break
            fi
            echo -n "."
            sleep 5
        done
        echo ""
        log_info "Resolver endpoint deleted"

        # Delete resolver security group
        if [ -n "$RESOLVER_SG" ] && [ "$RESOLVER_SG" != "None" ]; then
            log_info "Deleting resolver security group: $RESOLVER_SG"
            aws ec2 delete-security-group \
                --region "$REGION" \
                --group-id "$RESOLVER_SG" 2>/dev/null || log_warn "Failed to delete resolver security group"
        fi
    else
        log_info "Route53 Resolver Inbound Endpoint not found"
    fi

    # Delete S3 Interface Endpoint
    ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.${REGION}.s3" "Name=vpc-endpoint-type,Values=Interface" \
        --query 'VpcEndpoints[0].VpcEndpointId' \
        --output text 2>/dev/null || echo "")

    if [ "$ENDPOINT_ID" != "None" ] && [ -n "$ENDPOINT_ID" ]; then
        log_info "Deleting S3 Interface Endpoint: $ENDPOINT_ID"

        # Get security groups before deletion
        ENDPOINT_SGS=$(aws ec2 describe-vpc-endpoints \
            --region "$REGION" \
            --vpc-endpoint-ids "$ENDPOINT_ID" \
            --query 'VpcEndpoints[0].Groups[*].GroupId' \
            --output text)

        aws ec2 delete-vpc-endpoints \
            --region "$REGION" \
            --vpc-endpoint-ids "$ENDPOINT_ID" >/dev/null
        log_info "S3 Interface Endpoint deleted"

        # Delete endpoint security groups
        for sg_id in $ENDPOINT_SGS; do
            SG_NAME=$(aws ec2 describe-security-groups \
                --region "$REGION" \
                --group-ids "$sg_id" \
                --query 'SecurityGroups[0].GroupName' \
                --output text 2>/dev/null || echo "")

            if [[ "$SG_NAME" == "s3-interface-endpoint-sg" ]]; then
                log_info "Deleting S3 endpoint security group: $sg_id"
                sleep 5  # Wait for endpoint deletion to propagate
                aws ec2 delete-security-group \
                    --region "$REGION" \
                    --group-id "$sg_id" 2>/dev/null || log_warn "Failed to delete security group"
            fi
        done
    else
        log_info "S3 Interface Endpoint not found"
    fi

    echo ""
}

# Optional: Delete S3 buckets
cleanup_s3_buckets() {
    log_warn "=== S3 Bucket Cleanup ==="
    log_warn "Note: This will NOT delete your S3 buckets by default"
    log_warn "Standard bucket: $STANDARD_BUCKET"
    echo ""

    read -p "Do you want to DELETE the S3 Standard bucket and all its contents? (yes/no): " delete_bucket

    if [ "$delete_bucket" = "yes" ]; then
        log_info "Deleting all objects in bucket: $STANDARD_BUCKET"

        # Delete all object versions (including delete markers)
        aws s3api delete-objects \
            --bucket "$STANDARD_BUCKET" \
            --region "$REGION" \
            --delete "$(aws s3api list-object-versions \
                --bucket "$STANDARD_BUCKET" \
                --region "$REGION" \
                --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
                --max-items 1000)" 2>/dev/null || true

        aws s3api delete-objects \
            --bucket "$STANDARD_BUCKET" \
            --region "$REGION" \
            --delete "$(aws s3api list-object-versions \
                --bucket "$STANDARD_BUCKET" \
                --region "$REGION" \
                --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
                --max-items 1000)" 2>/dev/null || true

        # Delete bucket
        aws s3api delete-bucket \
            --bucket "$STANDARD_BUCKET" \
            --region "$REGION"
        log_info "Bucket deleted: $STANDARD_BUCKET"
    else
        log_info "Skipping bucket deletion"
    fi

    echo ""
}

# Main execution
main() {
    cleanup_phase2
    cleanup_phase1
    cleanup_s3_buckets

    # Clean up output files
    if [ -f "${SCRIPT_DIR}/../phase1-output.json" ]; then
        rm -f "${SCRIPT_DIR}/../phase1-output.json"
    fi

    if [ -f "${SCRIPT_DIR}/../phase2-output.json" ]; then
        rm -f "${SCRIPT_DIR}/../phase2-output.json"
    fi

    log_info "Cleanup completed!"
    log_info "Note: Express bucket and VPC resources were not deleted (manual cleanup required)"
}

main
