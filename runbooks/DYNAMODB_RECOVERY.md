# Runbook: DynamoDB Point-in-Time Recovery

**Severity**: CRITICAL  
**Response Time**: < 2 hours  
**Runbook Owner**: DevOps/Database Team

---

## When to Use

- DynamoDB table corrupted
- Accidental delete of services
- Need to restore to specific point in time
- Data integrity violation detected

---

## Prerequisites

- DynamoDB PITR enabled (auto-enabled in this solution)
- AWS CLI configured
- IAM permissions for DynamoDB restore

---

## Steps

### Step 1: Identify Point-in-Time to Restore

```bash
# Get baseline initialization time (oldest valid state)
aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item.first_seen'

# This is your earliest valid restore point

# Check what timestamp had the issue
# Look in CloudWatch Logs for when integrity violation occurred
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "BASELINE INTEGRITY\|Checksum" \
  | jq '.Events[0].timestamp'
```

### Step 2: Create Restore Request

```bash
# Calculate restore time (go back 2 hours or to last known good)
RESTORE_TIME=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S)

# Initiate restore (creates new table)
aws dynamodb restore-table-from-backup \
  --backup-arn arn:aws:dynamodb:eu-west-2:ACCOUNT:table/aws-service-monitor-registry/backup/01234567890123-a1b2c3d4 \
  --region eu-west-2
  
# OR restore to point-in-time
aws dynamodb restore-table-to-point-in-time \
  --source-table-name aws-service-monitor-registry \
  --target-table-name aws-service-monitor-registry-restored \
  --restore-date-time $(date -d "$RESTORE_TIME" +%s) \
  --region eu-west-2
```

### Step 3: Wait for Restore Completion

```bash
# Monitor restore progress (takes 1-2 hours)
watch -n 10 'aws dynamodb describe-table \
  --table-name aws-service-monitor-registry-restored \
  --region eu-west-2 | jq "{Status: .Table.TableStatus, Created: .Table.CreationDateTime}"'

# Wait until Status = ACTIVE
```

### Step 4: Verify Restored Data

```bash
# Count items in restored table
aws dynamodb scan \
  --table-name aws-service-monitor-registry-restored \
  --select COUNT \
  | jq '.Count'

# Compare with original (should match)
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --select COUNT \
  | jq '.Count'

# Verify baseline marker exists and is correct
aws dynamodb get-item \
  --table-name aws-service-monitor-registry-restored \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item'
```

### Step 5: Backup Original Table

```bash
# Don't delete original yet - create backup first
aws dynamodb create-backup \
  --table-name aws-service-monitor-registry \
  --backup-name pre-restore-backup-$(date +%Y%m%d-%H%M%S) \
  --region eu-west-2

# Wait for backup to complete
aws dynamodb describe-backup \
  --backup-arn arn:aws:dynamodb:eu-west-2:ACCOUNT:table/aws-service-monitor-registry/backup/01234567890123-a1b2c3d4 \
  | jq '.BackupDescription.BackupDetails | {BackupStatus, BackupSizeBytes}'
```

### Step 6: Swap Tables

```bash
# Option A: Rename tables (if using Terraform)
# 1. Backup current table with suffix
aws dynamodb create-backup \
  --table-name aws-service-monitor-registry \
  --backup-name pre-swap-backup-$(date +%Y%m%d-%H%M%S)

# 2. Delete original
aws dynamodb delete-table \
  --table-name aws-service-monitor-registry

# 3. Rename restored -> original
aws dynamodb tag-resource \
  --resource-arn arn:aws:dynamodb:eu-west-2:ACCOUNT:table/aws-service-monitor-registry-restored \
  --tags AttributeName=OriginalName,AttributeValue=aws-service-monitor-registry

# Re-create with Terraform or manually rename

# Option B: Copy data (safer)
# 1. Write DMS/Lambda to copy data from restored to original
# 2. Verify data copied
# 3. Delete restored table
```

### Step 7: Re-activate Lambda

```bash
# Update environment variable if table name changed
aws lambda update-function-configuration \
  --function-name aws-service-monitor \
  --environment Variables='{...DYNAMODB_TABLE=aws-service-monitor-registry...}' \
  --region eu-west-2

# Verify Lambda can access table
aws lambda invoke \
  --function-name aws-service-monitor \
  --payload '{}' \
  --region eu-west-2 \
  test-response.json

cat test-response.json | jq '.'
```

---

## Verification

```bash
# Check that Lambda baseline integrity check passes
aws logs tail /aws/lambda/aws-service-monitor \
  --follow --filter-pattern "Baseline integrity verified"

# Verify no alarms firing
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --region eu-west-2 | jq '.MetricAlarms[] | .AlarmName'

# Should see no alarms or only expected ones
```

---

## Cleanup

```bash
# Delete restored table if swap was successful
aws dynamodb delete-table \
  --table-name aws-service-monitor-registry-restored \
  --region eu-west-2

# Delete old backup if all checks pass
aws dynamodb delete-backup \
  --backup-arn arn:aws:dynamodb:eu-west-2:ACCOUNT:table/aws-service-monitor-registry/backup/OLD_BACKUP_ID
```

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24  
**Review Date**: 2026-05-24
