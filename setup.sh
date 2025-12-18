#!/bin/bash
set -e

# Main setup script for S3 Sync automation
# This script orchestrates the complete setup process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."

    local missing_deps=()

    command -v aws >/dev/null 2>&1 || missing_deps+=("aws-cli")
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v yq >/dev/null 2>&1 || missing_deps+=("yq")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: sudo yum install -y aws-cli jq"
        log_info "Install yq: wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq"
        exit 1
    fi

    log_info "All dependencies satisfied"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        log_info "Please copy config.yaml.example to config.yaml and fill in your values"
        exit 1
    fi

    log_info "Configuration loaded from $CONFIG_FILE"
}

show_usage() {
    cat << EOF
Usage: $0 [OPTION]

Setup automation for S3 sync from JD Cloud to AWS S3 Express One Zone

Options:
    phase1          Setup Phase 1: Network, S3 Interface Endpoint, Route53 Resolver
    phase2          Setup Phase 2: Lambda function and S3 event notification
    all             Run complete setup (Phase 1 + Phase 2)
    verify          Verify the setup
    cleanup         Remove all resources created by this script
    help            Show this help message

Examples:
    $0 phase1       # Setup network and endpoints only
    $0 all          # Complete setup
    $0 verify       # Verify configuration

EOF
}

run_phase1() {
    log_info "Starting Phase 1 setup..."
    bash "${SCRIPT_DIR}/scripts/setup-phase1.sh"
    log_info "Phase 1 completed successfully"
}

run_phase2() {
    log_info "Starting Phase 2 setup..."
    bash "${SCRIPT_DIR}/scripts/setup-phase2.sh"
    log_info "Phase 2 completed successfully"
}

verify_setup() {
    log_info "Verifying setup..."
    bash "${SCRIPT_DIR}/scripts/verify.sh"
}

cleanup_all() {
    log_warn "This will delete all resources created by this script"
    read -p "Are you sure? (yes/no): " confirmation

    if [ "$confirmation" = "yes" ]; then
        log_info "Starting cleanup..."
        bash "${SCRIPT_DIR}/scripts/cleanup.sh"
        log_info "Cleanup completed"
    else
        log_info "Cleanup cancelled"
    fi
}

# Main execution
case "${1:-help}" in
    phase1)
        check_dependencies
        load_config
        run_phase1
        ;;
    phase2)
        check_dependencies
        load_config
        run_phase2
        ;;
    all)
        check_dependencies
        load_config
        run_phase1
        run_phase2
        log_info "Complete setup finished successfully!"
        ;;
    verify)
        check_dependencies
        load_config
        verify_setup
        ;;
    cleanup)
        check_dependencies
        load_config
        cleanup_all
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac
