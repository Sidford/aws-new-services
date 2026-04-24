# Runbook: Baseline Reset Procedure

**Severity**: HIGH  
**Response Time**: < 30 minutes  
**Runbook Owner**: DevOps/Platform Team

---

## When to Use

- Baseline is corrupted and unrecoverable
- Both DynamoDB PITR and S3 restore failed
- Need to start fresh baseline
- All other recovery options exhausted

---

## WARNING

This procedure **LOSES** historical service tracking. Use only after exhausting other recovery options.

---

## Procedure

### Step 1: Backup Current State

```bash
# Always backup first
aws dynamodb create-backup \
  --table-name aws-service-monitor-registry \
  --backup-name pre-reset-backup-$(date +%Y%m%d-%H%M%S)

# Export table to S3 for archival
aws dynamodb export-table-to-point-in-time \
  --table-arn arn:aws:dynamodb:us-east-1:ACCOUNT:table/aws-service-monitor-registry \
  --s3-bucket my-backup-bucket \
  --s3-prefix service-monitor-export-$(date +%Y%m%d-%H%M%S) \
  --export-format JSON
```

### Step 2: Delete Baseline Marker

```bash
# This triggers reinitialization on next run
aws dynamodb delete-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  --region us-east-1
```

### Step 3: Preserve or Delete Services

**Option A**: Keep existing services (faster)
```bash
# Do nothing - existing services are preserved
# Next Lambda run will check against them
```

**Option B**: Delete all services (clean slate)
```bash
# Warning: Deletes all service tracking!
# Use only if starting completely fresh

aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --filter-expression "NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  --projection-expression service_name \
  | jq '.Items[].service_name.S' \
  | xargs -I {} aws dynamodb delete-item \
    --table-name aws-service-monitor-registry \
    --key "{\"service_name\":{\"S\":\"{}\"}}"
```

### Step 4: Trigger Reinitialization

```bash
# Manually invoke Lambda - it will detect no baseline
aws lambda invoke \
  --function-name aws-service-monitor \
  --payload '{}' \
  --region us-east-1 \
  init-response.json

# Check response
cat init-response.json | jq '.'

# Should see: "status": "baseline_initialized"
```

### Step 5: Verify New Baseline

```bash
# Check baseline was created
aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item | {service_count: .service_count, checksum: .checksum}'

# Count services
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --select COUNT \
  --filter-expression "NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  | jq '.Count'

# Verify S3 snapshot created
aws s3 ls s3://service-monitor-baseline-ACCOUNT-us-east-1/baseline-snapshots/ \
  | tail -1
```

---

## Verification

```bash
# Check next execution passes integrity check
aws logs tail /aws/lambda/aws-service-monitor \
  --follow --filter-pattern "Baseline integrity verified"

# Monitor for alarms
aws cloudwatch describe-alarms \
  --state-value ALARM

# Should see no integrity alarms
```

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24
