# Testing Guide: Service Detection & Baseline Management

This guide covers manual testing scenarios for the AWS Service Monitor, with a focus on safely managing baseline integrity during tests.

## Overview

The system uses a baseline checksum to detect tampering. When testing service detection workflows (removing/adding services), you must carefully manage both the services AND the checksum to avoid false tampering alerts.

## Safe Testing with the Helper Script

A helper script (`scripts/test-baseline-management.sh`) automates baseline management during testing. **Always use this script instead of manual DynamoDB edits.**

### Quick Start

```bash
# 1. Backup and prepare for testing
./scripts/test-baseline-management.sh remove sagemaker

# 2. Invoke Lambda to detect the "new" service
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json

# 3. Restore original baseline
./scripts/test-baseline-management.sh restore
```

### Script Commands

#### Backup Current State
```bash
./scripts/test-baseline-management.sh backup
```
- Captures the current baseline checksum and list of services
- Saves to `/tmp/baseline_backup_<timestamp>.json`
- Required before any test modifications

#### Remove Service & Prepare for Testing
```bash
./scripts/test-baseline-management.sh remove <service_name>
```
- Removes the service from DynamoDB
- Recalculates and updates baseline checksum to match the reduced service set
- Sets up the scenario for Lambda to detect the service as "new" on next run

**Example:**
```bash
./scripts/test-baseline-management.sh remove sagemaker
```

#### Restore Original Baseline
```bash
./scripts/test-baseline-management.sh restore
```
- Restores the original baseline checksum
- Re-adds any deleted services
- Cleans up the backup file
- **Must be run after testing to prevent false tampering alerts**

#### View Current State
```bash
./scripts/test-baseline-management.sh state
```
- Shows current baseline checksum and service count
- Compares against backup (if one exists)
- Helps verify consistency before/after tests

## Manual Testing Workflow

### Scenario: Test New Service Detection

**Goal:** Verify that Lambda detects a previously-tracked service as "new" when it's removed and re-added.

#### Step 1: Backup Current State
```bash
./scripts/test-baseline-management.sh backup
# Output: Baseline backed up to: /tmp/baseline_backup_1777104000.json
#   Checksum: 857af894...
#   Services: 447
```

#### Step 2: Remove Service & Update Baseline
```bash
./scripts/test-baseline-management.sh remove sagemaker
# Output: Service deleted: sagemaker
#   New checksum: abc12345...
#   Remaining services: 446
```

The script:
- Deletes `sagemaker` from DynamoDB
- Recalculates the checksum for the remaining 446 services
- Updates the baseline marker with the new checksum

#### Step 3: Invoke Lambda
```bash
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json

cat response.json
```

Lambda will:
- Fetch 447 services from AWS reference (including sagemaker)
- Find 446 tracked services in DynamoDB (sagemaker missing)
- Detect sagemaker as "new"
- Add it back to DynamoDB
- Send notification email

**Expected Response:**
```json
{
  "message": "Processed 1 new services",
  "new_services": ["sagemaker"],
  "scp_status": "success",
  "scan_time": "2026-04-25T15:30:00.123456"
}
```

#### Step 4: Verify in CloudWatch Logs
```bash
aws logs tail /aws/lambda/aws-service-monitor \
  --region eu-west-2 \
  --since 5m \
  --follow
```

Look for:
- `Fetched 447 services from AWS reference`
- `Retrieved 446 tracked services from DynamoDB`
- `New services: 1`
- `Processed 1 new services`
- `Sent email notification`

#### Step 5: Restore Original Baseline
```bash
./scripts/test-baseline-management.sh restore
# Output: Baseline fully restored
#   Services: 447
#   Checksum: 857af894...
```

The script:
- Restores original checksum
- Re-adds the sagemaker service
- Verifies consistency

#### Step 6: Verify Restoration
```bash
./scripts/test-baseline-management.sh state
# Output: Checksums match - baseline is consistent
```

## Testing Without SCP Management

If testing with `MANAGE_SCP_POLICY = false` (notifications-only mode):

```bash
# Same workflow, but Lambda will skip SCP operations
# Email will omit SCP sections automatically
```

## Common Issues & Fixes

### Issue: Tampering Alert on Next Run

**Symptom:** After testing, Lambda sends "Baseline Integrity Violation" alert

**Cause:** Forgot to run `restore` command, or restore failed

**Fix:**
```bash
# Check current state
./scripts/test-baseline-management.sh state

# If checksums don't match, restore
./scripts/test-baseline-management.sh restore

# Verify
./scripts/test-baseline-management.sh state
```

### Issue: Backup File Not Found

**Symptom:** `Error: Backup file not found`

**Cause:** Backup file was deleted or script was interrupted

**Fix:**
```bash
# Get the correct checksum from S3 baseline snapshots
aws s3 ls s3://service-monitor-baseline-*/baseline-snapshots/ \
  --region eu-west-2 \
  --profile sidford-mgmt

# Download the latest snapshot
aws s3 cp s3://service-monitor-baseline-ACCOUNT-REGION/baseline-snapshots/TIMESTAMP.json - \
  --region eu-west-2 \
  --profile sidford-mgmt | jq '.checksum'

# Manually restore checksum
aws dynamodb update-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  --update-expression "SET checksum = :checksum" \
  --expression-attribute-values '{":checksum":{"S":"<CHECKSUM_FROM_S3>"}}' \
  --region eu-west-2 \
  --profile sidford-mgmt
```

## Testing Multiple Services

To remove multiple services:

```bash
# Remove services one at a time
./scripts/test-baseline-management.sh remove service1
./scripts/test-baseline-management.sh remove service2  # Updates from previous state
./scripts/test-baseline-management.sh remove service3

# Invoke Lambda - it will detect all 3 as new

# Restore in reverse order or all at once
./scripts/test-baseline-management.sh restore
```

## Testing SCP Integration

### Test SCP Update Success
```bash
./scripts/test-baseline-management.sh remove newservice

# Invoke Lambda with SCP enabled
# Verify email includes SCP status

./scripts/test-baseline-management.sh restore
```

### Test SCP Management Disabled
```bash
# Set environment variable or modify Lambda config
# MANAGE_SCP_POLICY = false

./scripts/test-baseline-management.sh remove newservice

# Invoke Lambda
# Verify email omits SCP sections

./scripts/test-baseline-management.sh restore
```

## Integration Testing Against Real AWS

For integration tests against your actual AWS environment:

1. **Use a staging AWS account first** (not management account)
2. Run through the full workflow
3. Verify CloudWatch logs, DynamoDB state, and email notifications
4. Always restore baseline before moving to production

## Automated Testing

Unit tests in `lambda/test_index.py` include scenarios for:
- Service removal and rediscovery
- Baseline integrity checking
- Email notifications
- SCP integration (success/failure cases)

Run tests:
```bash
cd lambda
python -m pytest test_index.py -v
```

Tests automatically manage checksums via helper functions and don't require manual cleanup.

## Best Practices

1. **Always backup before testing**
   ```bash
   ./scripts/test-baseline-management.sh backup
   ```

2. **Always restore after testing**
   ```bash
   ./scripts/test-baseline-management.sh restore
   ```

3. **Verify state before and after**
   ```bash
   ./scripts/test-baseline-management.sh state
   ```

4. **Test in non-production first**
   - Use staging account to verify workflow
   - Only test in management account after validating

5. **Keep backups**
   - The script saves backups to `/tmp/`
   - For critical testing, manually archive the backup file
   ```bash
   cp /tmp/baseline_backup_*.json ~/my_backups/
   ```

6. **Document what you tested**
   - Record which services were removed
   - Note the Lambda execution times
   - Capture CloudWatch logs for review

## Environment Variables

All commands respect these environment variables:

```bash
# Set region
export AWS_REGION=eu-west-2

# Set profile
export AWS_PROFILE=sidford-mgmt

# Set table name (if non-standard)
export DYNAMODB_TABLE=aws-service-monitor-registry
```

Or pass them inline:
```bash
AWS_PROFILE=sidford-mgmt AWS_REGION=eu-west-2 \
  ./scripts/test-baseline-management.sh backup
```

## Troubleshooting

### Script Fails: "AWS credentials not found"
```bash
# Configure AWS profile
aws configure --profile sidford-mgmt

# Or verify existing profile
aws sts get-caller-identity --profile sidford-mgmt
```

### Script Fails: "jq command not found"
```bash
# Install jq
# macOS
brew install jq

# Linux
sudo apt-get install jq

# Or use Docker
docker run --rm stedolan/jq --version
```

### DynamoDB Table Not Found
```bash
# Verify table exists
aws dynamodb describe-table \
  --table-name aws-service-monitor-registry \
  --region eu-west-2 \
  --profile sidford-mgmt

# Or list all tables
aws dynamodb list-tables --region eu-west-2 --profile sidford-mgmt
```

## Support

For issues or questions:
1. Check CloudWatch logs: `/aws/lambda/aws-service-monitor`
2. Check DynamoDB baseline marker: `__baseline_initialized__`
3. Verify S3 baseline snapshots: `s3://service-monitor-baseline-*/baseline-snapshots/`
4. Review this guide and the main CLAUDE.md documentation
