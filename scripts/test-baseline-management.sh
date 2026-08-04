#!/bin/bash
# Test Baseline Management Helper
# Safely manages baseline checksum during manual testing
# Captures original state, allows modifications, and restores cleanly

set -e

# Configuration
DYNAMODB_TABLE="${DYNAMODB_TABLE:-aws-service-monitor-registry}"
AWS_REGION="${AWS_REGION:-eu-west-2}"
AWS_PROFILE="${AWS_PROFILE:-sidford-mgmt}"
BASELINE_MARKER="__baseline_initialized__"
BACKUP_FILE="/tmp/baseline_backup_${DYNAMODB_TABLE}.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

# Backup current baseline state
backup_baseline() {
    log_info "Backing up current baseline state..."

    # Get baseline marker
    baseline=$(aws dynamodb get-item \
        --table-name "$DYNAMODB_TABLE" \
        --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --output json)

    if [ -z "$baseline" ] || echo "$baseline" | grep -q "\"Item\":{}"; then
        log_error "Baseline marker not found in DynamoDB"
        return 1
    fi

    # Extract checksum
    checksum=$(echo "$baseline" | jq -r '.Item.checksum.S')
    if [ -z "$checksum" ]; then
        log_error "No checksum found in baseline marker"
        return 1
    fi

    # Get all services (excluding metadata)
    services=$(aws dynamodb scan \
        --table-name "$DYNAMODB_TABLE" \
        --filter-expression "NOT begins_with(service_name, :prefix)" \
        --expression-attribute-values "{\":prefix\":{\"S\":\"__\"}}" \
        --projection-expression "service_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --output json | jq -r '.Items[].service_name.S' | sort)

    service_count=$(echo "$services" | wc -l)

    # Create backup file
    cat > "$BACKUP_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "checksum": "$checksum",
  "service_count": $service_count,
  "services": [
$(echo "$services" | jq -R -s -c '[inputs] | map(select(length > 0))' | jq '.[0][]' 2>/dev/null | awk '{print "    \"" $0 "\""}' | paste -sd, - | sed 's/,$//')
  ]
}
EOF

    log_success "Baseline backed up to: $BACKUP_FILE"
    log_info "  Checksum: ${checksum:0:8}..."
    log_info "  Services: $service_count"
}

# Get the original checksum
get_original_checksum() {
    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        return 1
    fi
    jq -r '.checksum' "$BACKUP_FILE"
}

# Remove a service and update checksum for testing
test_service_removal() {
    local service_to_remove=$1

    if [ -z "$service_to_remove" ]; then
        log_error "Service name required: test_service_removal <service_name>"
        return 1
    fi

    log_info "Removing service '$service_to_remove' for testing..."

    # Delete the service
    aws dynamodb delete-item \
        --table-name "$DYNAMODB_TABLE" \
        --key "{\"service_name\":{\"S\":\"$service_to_remove\"}}" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" > /dev/null

    log_success "Service deleted: $service_to_remove"

    # Get remaining services
    remaining=$(aws dynamodb scan \
        --table-name "$DYNAMODB_TABLE" \
        --filter-expression "NOT begins_with(service_name, :prefix)" \
        --expression-attribute-values "{\":prefix\":{\"S\":\"__\"}}" \
        --projection-expression "service_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --output json | jq -r '.Items[].service_name.S' | sort)

    remaining_count=$(echo "$remaining" | grep -c . || true)

    # Calculate new checksum for remaining services
    new_checksum=$(python3 -c "
import json
import hashlib
services = '''$remaining'''.strip().split('\n')
services = [s for s in services if s]
service_string = json.dumps(services, separators=(',', ':'))
checksum = hashlib.sha256(service_string.encode()).hexdigest()
print(checksum)
")

    # Update baseline checksum
    aws dynamodb update-item \
        --table-name "$DYNAMODB_TABLE" \
        --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
        --update-expression "SET checksum = :checksum, service_count = :count" \
        --expression-attribute-values "{\":checksum\":{\"S\":\"$new_checksum\"}, \":count\":{\"N\":\"$remaining_count\"}}" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" > /dev/null

    log_success "Baseline checksum updated for test scenario"
    log_info "  New checksum: ${new_checksum:0:8}..."
    log_info "  Remaining services: $remaining_count"
    log_warn "Ready for testing. Run: aws lambda invoke --function-name aws-service-monitor ... response.json"
}

# Restore original baseline state
restore_baseline() {
    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        log_error "Cannot restore without backup"
        return 1
    fi

    log_info "Restoring original baseline state..."

    original_checksum=$(jq -r '.checksum' "$BACKUP_FILE")
    services=$(jq -r '.services[]' "$BACKUP_FILE")
    service_count=$(jq -r '.service_count' "$BACKUP_FILE")

    # Update baseline checksum to original
    aws dynamodb update-item \
        --table-name "$DYNAMODB_TABLE" \
        --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
        --update-expression "SET checksum = :checksum, service_count = :count" \
        --expression-attribute-values "{\":checksum\":{\"S\":\"$original_checksum\"}, \":count\":{\"N\":\"$service_count\"}}" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" > /dev/null

    log_success "Baseline checksum restored: ${original_checksum:0:8}..."

    # Re-add any services that were deleted during testing
    current_services=$(aws dynamodb scan \
        --table-name "$DYNAMODB_TABLE" \
        --filter-expression "NOT begins_with(service_name, :prefix)" \
        --expression-attribute-values "{\":prefix\":{\"S\":\"__\"}}" \
        --projection-expression "service_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --output json | jq -r '.Items[].service_name.S' | sort)

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%fZ)

    # Find and restore missing services
    while IFS= read -r service; do
        if ! echo "$current_services" | grep -q "^${service}$"; then
            log_info "Re-adding service: $service"
            aws dynamodb put-item \
                --table-name "$DYNAMODB_TABLE" \
                --item "{\"service_name\":{\"S\":\"$service\"},\"first_seen\":{\"S\":\"$timestamp\"},\"last_updated\":{\"S\":\"$timestamp\"},\"is_baseline\":{\"BOOL\":true}}" \
                --region "$AWS_REGION" \
                --profile "$AWS_PROFILE" > /dev/null
        fi
    done <<< "$services"

    log_success "Baseline fully restored"
    log_info "  Services: $service_count"
    log_info "  Checksum: ${original_checksum:0:8}..."

    # Clean up backup file
    rm -f "$BACKUP_FILE"
    log_info "Backup file cleaned up"
}

# Show current state
show_state() {
    log_info "Current Baseline State:"

    baseline=$(aws dynamodb get-item \
        --table-name "$DYNAMODB_TABLE" \
        --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --output json)

    checksum=$(echo "$baseline" | jq -r '.Item.checksum.S // "NOT FOUND"')
    service_count=$(echo "$baseline" | jq -r '.Item.service_count.N // 0')

    log_info "  Baseline Checksum: ${checksum:0:16}..."
    log_info "  Tracked Services: $service_count"

    if [ -f "$BACKUP_FILE" ]; then
        backup_checksum=$(jq -r '.checksum' "$BACKUP_FILE")
        backup_count=$(jq -r '.service_count' "$BACKUP_FILE")
        log_info "  Backup Checksum: ${backup_checksum:0:16}..."
        log_info "  Backup Service Count: $backup_count"

        if [ "$checksum" != "$backup_checksum" ]; then
            log_warn "Checksums differ - restore recommended"
        else
            log_success "Checksums match - baseline is consistent"
        fi
    fi
}

# Main menu
show_usage() {
    cat <<EOF
${BLUE}Test Baseline Management Helper${NC}

Usage: $0 <command> [options]

Commands:
  backup <backup_file>              Backup current baseline state
  remove <service_name>             Remove service and update checksum for testing
  restore                           Restore original baseline from backup
  state                             Show current baseline and backup state
  help                              Show this help message

Environment Variables:
  DYNAMODB_TABLE    DynamoDB table name (default: aws-service-monitor-registry)
  AWS_REGION        AWS region (default: eu-west-2)
  AWS_PROFILE       AWS profile (default: sidford-mgmt)

Examples:
  # Backup current state
  $0 backup

  # Remove a service and prepare for testing
  $0 remove sagemaker

  # Invoke Lambda to detect the "new" service
  aws lambda invoke --function-name aws-service-monitor --region eu-west-2 response.json

  # Restore original baseline
  $0 restore

  # Check current state
  $0 state

EOF
}

# Main script
main() {
    local command=${1:-help}

    case "$command" in
        backup)
            backup_baseline
            ;;
        remove)
            if [ -z "$2" ]; then
                log_error "Service name required"
                show_usage
                exit 1
            fi
            backup_baseline
            test_service_removal "$2"
            ;;
        restore)
            restore_baseline
            ;;
        state)
            show_state
            ;;
        help)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
