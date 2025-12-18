#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.yaml"

source "${SCRIPT_DIR}/common.sh"

# Load configuration
REGION=$(yq '.aws.region' "$CONFIG_FILE")
VPC_ID=$(yq '.phase1.vpc.vpc_id' "$CONFIG_FILE")
SUBNET_IDS=($(yq '.phase1.vpc.subnet_ids[]' "$CONFIG_FILE"))
JD_CLOUD_CIDRS=($(yq '.phase1.jd_cloud_cidr[]' "$CONFIG_FILE"))
STANDARD_BUCKET=$(yq '.phase1.standard_bucket.name' "$CONFIG_FILE")
BUCKET_AUTO_CREATE=$(yq '.phase1.standard_bucket.auto_create' "$CONFIG_FILE")
RESOLVER_NAME=$(yq '.phase1.resolver.name' "$CONFIG_FILE")

log_info "Phase 1: Setting up network and S3 Interface Endpoint"
log_info "Region: $REGION"
log_info "VPC: $VPC_ID"

# Step 1: Create Security Group for S3 Interface Endpoint
create_s3_endpoint_sg() {
    log_info "Creating Security Group for S3 Interface Endpoint..."

    SG_NAME="s3-interface-endpoint-sg"
    SG_DESC="Security group for S3 Interface Endpoint - allow HTTPS from JD Cloud"

    # Check if SG already exists
    SG_ID=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")

    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        SG_ID=$(aws ec2 create-security-group \
            --region "$REGION" \
            --group-name "$SG_NAME" \
            --description "$SG_DESC" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)
        log_info "Created Security Group: $SG_ID"

        # Add ingress rules for each JD Cloud CIDR
        for cidr in "${JD_CLOUD_CIDRS[@]}"; do
            # Check if rule already exists
            if ! aws ec2 describe-security-group-rules \
                --region "$REGION" \
                --filters "Name=group-id,Values=$SG_ID" \
                --query "SecurityGroupRules[?IpProtocol=='tcp' && FromPort==\`443\` && ToPort==\`443\` && CidrIpv4=='$cidr']" \
                --output text | grep -q .; then
                aws ec2 authorize-security-group-ingress \
                    --region "$REGION" \
                    --group-id "$SG_ID" \
                    --protocol tcp \
                    --port 443 \
                    --cidr "$cidr" >/dev/null
                log_info "Added ingress rule: 443/TCP from $cidr"
            else
                log_info "Ingress rule already exists: 443/TCP from $cidr"
            fi
        done
    else
        log_info "Security Group already exists: $SG_ID"
    fi

    echo "$SG_ID"
}

# Step 2: Create S3 Interface Endpoint
create_s3_interface_endpoint() {
    local sg_id=$1

    log_info "Creating S3 Interface Endpoint..."

    SERVICE_NAME="com.amazonaws.${REGION}.s3"

    # Check if endpoint already exists
    ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$SERVICE_NAME" "Name=vpc-endpoint-type,Values=Interface" \
        --query 'VpcEndpoints[0].VpcEndpointId' \
        --output text 2>/dev/null || echo "")

    if [ "$ENDPOINT_ID" = "None" ] || [ -z "$ENDPOINT_ID" ]; then
        SUBNET_IDS_JSON=$(printf '%s\n' "${SUBNET_IDS[@]}" | jq -R . | jq -s .)

        ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
            --region "$REGION" \
            --vpc-id "$VPC_ID" \
            --vpc-endpoint-type Interface \
            --service-name "$SERVICE_NAME" \
            --subnet-ids "${SUBNET_IDS[@]}" \
            --security-group-ids "$sg_id" \
            --private-dns-enabled false \
            --query 'VpcEndpoint.VpcEndpointId' \
            --output text)
        log_info "Created S3 Interface Endpoint: $ENDPOINT_ID"

        # Wait for endpoint to be available
        log_info "Waiting for endpoint to become available..."
        aws ec2 wait vpc-endpoint-available --region "$REGION" --vpc-endpoint-ids "$ENDPOINT_ID"
        log_info "Endpoint is now available"
    else
        log_info "S3 Interface Endpoint already exists: $ENDPOINT_ID"
    fi

    echo "$ENDPOINT_ID"
}

# Step 3: Create Route 53 Resolver Inbound Endpoint
create_resolver_inbound_endpoint() {
    log_info "Creating Route 53 Resolver Inbound Endpoint..."

    # Check if resolver endpoint already exists
    RESOLVER_ID=$(aws route53resolver list-resolver-endpoints \
        --region "$REGION" \
        --query "ResolverEndpoints[?Name=='$RESOLVER_NAME'].Id | [0]" \
        --output text 2>/dev/null || echo "")

    if [ "$RESOLVER_ID" = "None" ] || [ -z "$RESOLVER_ID" ]; then
        # Create security group for resolver
        RESOLVER_SG_NAME="route53-resolver-inbound-sg"
        RESOLVER_SG_DESC="Security group for Route53 Resolver Inbound Endpoint"

        RESOLVER_SG_ID=$(aws ec2 describe-security-groups \
            --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$RESOLVER_SG_NAME" \
            --query 'SecurityGroups[0].GroupId' \
            --output text 2>/dev/null || echo "")

        if [ "$RESOLVER_SG_ID" = "None" ] || [ -z "$RESOLVER_SG_ID" ]; then
            RESOLVER_SG_ID=$(aws ec2 create-security-group \
                --region "$REGION" \
                --group-name "$RESOLVER_SG_NAME" \
                --description "$RESOLVER_SG_DESC" \
                --vpc-id "$VPC_ID" \
                --query 'GroupId' \
                --output text)
            log_info "Created Resolver Security Group: $RESOLVER_SG_ID"
        else
            log_info "Resolver Security Group already exists: $RESOLVER_SG_ID"
        fi

        # Add ingress rules if not exist (works for both new and existing SG)
        for cidr in "${JD_CLOUD_CIDRS[@]}"; do
            # Check TCP rule
            if ! aws ec2 describe-security-group-rules \
                --region "$REGION" \
                --filters "Name=group-id,Values=$RESOLVER_SG_ID" \
                --query "SecurityGroupRules[?IpProtocol=='tcp' && FromPort==\`53\` && ToPort==\`53\` && CidrIpv4=='$cidr']" \
                --output text | grep -q .; then
                aws ec2 authorize-security-group-ingress \
                    --region "$REGION" \
                    --group-id "$RESOLVER_SG_ID" \
                    --protocol tcp \
                    --port 53 \
                    --cidr "$cidr" >/dev/null
                log_info "Added Resolver ingress rule: 53/TCP from $cidr"
            else
                log_info "Resolver ingress rule already exists: 53/TCP from $cidr"
            fi
            # Check UDP rule
            if ! aws ec2 describe-security-group-rules \
                --region "$REGION" \
                --filters "Name=group-id,Values=$RESOLVER_SG_ID" \
                --query "SecurityGroupRules[?IpProtocol=='udp' && FromPort==\`53\` && ToPort==\`53\` && CidrIpv4=='$cidr']" \
                --output text | grep -q .; then
                aws ec2 authorize-security-group-ingress \
                    --region "$REGION" \
                    --group-id "$RESOLVER_SG_ID" \
                    --protocol udp \
                    --port 53 \
                    --cidr "$cidr" >/dev/null
                log_info "Added Resolver ingress rule: 53/UDP from $cidr"
            else
                log_info "Resolver ingress rule already exists: 53/UDP from $cidr"
            fi
        done

        # Build IP addresses JSON for resolver endpoint
        IP_ADDRESSES_JSON="["
        for i in "${!SUBNET_IDS[@]}"; do
            if [ $i -gt 0 ]; then IP_ADDRESSES_JSON+=","; fi
            IP_ADDRESSES_JSON+="{\"SubnetId\":\"${SUBNET_IDS[$i]}\"}"
        done
        IP_ADDRESSES_JSON+="]"

        RESOLVER_ID=$(aws route53resolver create-resolver-endpoint \
            --region "$REGION" \
            --creator-request-id "$(uuidgen)" \
            --name "$RESOLVER_NAME" \
            --security-group-ids "$RESOLVER_SG_ID" \
            --direction INBOUND \
            --ip-addresses "$IP_ADDRESSES_JSON" \
            --query 'ResolverEndpoint.Id' \
            --output text)
        log_info "Created Route53 Resolver Inbound Endpoint: $RESOLVER_ID"

        log_info "Waiting for resolver endpoint to be operational..."
        while true; do
            STATUS=$(aws route53resolver get-resolver-endpoint \
                --region "$REGION" \
                --resolver-endpoint-id "$RESOLVER_ID" \
                --query 'ResolverEndpoint.Status' \
                --output text)
            if [ "$STATUS" = "OPERATIONAL" ]; then
                break
            fi
            echo -n "."
            sleep 5
        done
        echo ""
        log_info "Resolver endpoint is now operational"
    else
        log_info "Route53 Resolver Inbound Endpoint already exists: $RESOLVER_ID"
    fi

    # Get resolver IP addresses
    RESOLVER_IPS=$(aws route53resolver get-resolver-endpoint \
        --region "$REGION" \
        --resolver-endpoint-id "$RESOLVER_ID" \
        --query 'ResolverEndpoint.IpAddresses[*].Ip' \
        --output text)

    log_info "Resolver IP addresses: $RESOLVER_IPS"
    log_warn "ACTION REQUIRED: Configure JD Cloud DNS forwarder to forward s3.${REGION}.amazonaws.com queries to: $RESOLVER_IPS"

    echo "$RESOLVER_ID"
}

# Step 4: Verify or Create S3 Standard Bucket
verify_or_create_standard_bucket() {
    log_info "Checking S3 Standard Bucket: $STANDARD_BUCKET"

    # Check if bucket exists
    if aws s3api head-bucket --bucket "$STANDARD_BUCKET" --region "$REGION" 2>/dev/null; then
        log_info "Bucket already exists: $STANDARD_BUCKET"

        # Check and enable versioning if not already enabled
        VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
            --bucket "$STANDARD_BUCKET" \
            --region "$REGION" \
            --query 'Status' \
            --output text 2>/dev/null || echo "")

        if [ "$VERSIONING_STATUS" != "Enabled" ]; then
            aws s3api put-bucket-versioning \
                --bucket "$STANDARD_BUCKET" \
                --region "$REGION" \
                --versioning-configuration Status=Enabled
            log_info "Enabled versioning on bucket"
        else
            log_info "Versioning already enabled on bucket"
        fi
    else
        # Bucket doesn't exist
        if [ "$BUCKET_AUTO_CREATE" = "true" ]; then
            log_info "Creating S3 Standard Bucket: $STANDARD_BUCKET"

            if [ "$REGION" = "us-east-1" ]; then
                aws s3api create-bucket \
                    --bucket "$STANDARD_BUCKET" \
                    --region "$REGION"
            else
                aws s3api create-bucket \
                    --bucket "$STANDARD_BUCKET" \
                    --region "$REGION" \
                    --create-bucket-configuration LocationConstraint="$REGION"
            fi
            log_info "Created bucket: $STANDARD_BUCKET"

            # Enable versioning on new bucket
            aws s3api put-bucket-versioning \
                --bucket "$STANDARD_BUCKET" \
                --region "$REGION" \
                --versioning-configuration Status=Enabled
            log_info "Enabled versioning on bucket"
        else
            log_error "Bucket does not exist: $STANDARD_BUCKET"
            log_error "Either create it manually or set 'auto_create: true' in config.yaml"
            exit 1
        fi
    fi
}

# Main execution
main() {
    log_info "Starting Phase 1 setup..."

    SG_ID=$(create_s3_endpoint_sg)
    ENDPOINT_ID=$(create_s3_interface_endpoint "$SG_ID")
    RESOLVER_ID=$(create_resolver_inbound_endpoint)
    verify_or_create_standard_bucket

    # Save output for Phase 2
    OUTPUT_FILE="${SCRIPT_DIR}/../phase1-output.json"
    cat > "$OUTPUT_FILE" << EOF
{
  "s3_endpoint_sg_id": "$SG_ID",
  "s3_interface_endpoint_id": "$ENDPOINT_ID",
  "resolver_endpoint_id": "$RESOLVER_ID",
  "resolver_ips": "$RESOLVER_IPS",
  "standard_bucket": "$STANDARD_BUCKET"
}
EOF

    log_info "Phase 1 setup completed successfully!"
    log_info "Output saved to: $OUTPUT_FILE"
    echo ""
    log_warn "Next steps:"
    log_warn "1. Configure JD Cloud DNS forwarder to forward s3.${REGION}.amazonaws.com to: $RESOLVER_IPS"
    log_warn "2. Test DNS resolution from JD Cloud: nslookup s3.${REGION}.amazonaws.com"
    log_warn "3. Test upload from JD Cloud: aws s3 cp testfile s3://${STANDARD_BUCKET}/incoming/"
    log_warn "4. Once verified, run Phase 2: ./setup.sh phase2"
}

main
