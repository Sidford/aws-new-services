# Runbook: Baseline Integrity Violation Response

**Severity**: CRITICAL  
**Response Time**: < 5 minutes  
**Runbook Owner**: Security/DevOps Team

---

## Quick Diagnosis

When does this trigger?
- CloudWatch Alarm: `service-monitor-baseline-integrity-violation` fires
- Metric: `BaselineIntegrityStatus` drops to 0
- Log message: "BASELINE INTEGRITY VIOLATION DETECTED"

What it means?
- The DynamoDB service baseline has been modified
- SHA256 checksum verification failed
- Possible unauthorized tampering or data corruption

---

## IMMEDIATE ACTIONS (0-5 minutes)

### Step 1: Confirm the Alert
```bash
# Check CloudWatch Alarm
aws cloudwatch describe-alarms \
  --alarm-names service-monitor-baseline-integrity-violation \
  --region eu-west-2

# Check last Lambda execution logs
aws logs tail /aws/lambda/aws-service-monitor \
  --follow --format short | grep -i "integrity\|baseline"
```

### Step 2: Access CloudWatch Logs
```bash
# Get detailed error information
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "BASELINE INTEGRITY" \
  --region eu-west-2 \
  --query 'events[0]' | jq -r '.message'
```

**What to look for**:
- Checksum mismatch details
- Number of services affected
- Timestamp of violation

### Step 3: Notify Stakeholders
- [ ] Alert security team immediately
- [ ] Notify infrastructure/platform team
- [ ] Document incident ticket with timestamp
- [ ] Prepare for potential incident escalation

---

## INVESTIGATION (5-30 minutes)

### Step 4: Identify Scope of Tampering

**Check what was modified**:
```bash
# Get expected baseline services from S3 snapshot
aws s3 cp s3://service-monitor-baseline-$(aws sts get-caller-identity --query Account --output text)-eu-west-2/baseline-snapshots/ . --recursive

# Get most recent snapshot
SNAPSHOT=$(ls baseline-snapshots/ | sort -r | head -1)
cat baseline-snapshots/$SNAPSHOT | jq '.services | length'

# Expected service count
echo "Expected services: $(cat baseline-snapshots/$SNAPSHOT | jq '.services | length')"

# Check actual DynamoDB service count
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --select COUNT \
  --filter-expression "attribute_not_exists(#sn) OR NOT begins_with(#sn, :prefix)" \
  --expression-attribute-names '{"#sn":"service_name"}' \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  | jq '.Count'
```

### Step 5: Review CloudTrail Logs

**Find unauthorized modifications**:
```bash
# Get recent DynamoDB API calls
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=aws-service-monitor-registry \
  --max-results 50 \
  --region eu-west-2 \
  --output table

# Focus on DeleteItem and UpdateItem operations
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=aws-service-monitor-registry \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteItem \
  --max-results 50 \
  | jq '.Events[] | {Time, Username, EventName}'
```

**Key questions**:
- Who made the modifications? (Username/principal)
- When were they made? (timestamp)
- Which services were deleted/modified?
- Was the __baseline_initialized__ marker modified?

### Step 6: Compare Data Integrity

**Verify checksums**:
```bash
# Get stored checksum from DynamoDB
aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item.checksum.S'

# Get expected checksum from S3 snapshot
cat baseline-snapshots/$SNAPSHOT | jq '.checksum'

# They should match - if they don't, S3 snapshot is source of truth
```

---

## RECOVERY (30 min - 2 hours)

### Step 7: Determine Recovery Strategy

**Option A**: Restore from S3 (PREFERRED - takes 15-30 minutes)
- Fastest recovery
- Data is forensically preserved
- S3 Object Lock prevents further tampering

**Option B**: Restore from DynamoDB PITR (takes 1-2 hours)
- Original service list restored to timestamp before tampering
- Slower but comprehensive recovery

**Option C**: Reinitialize baseline (takes 5 minutes)
- Only if both above fail
- New baseline from current services
- Loss of historical data

### Step 8: Execute Recovery - Option A (Recommended)

```bash
# 1. Backup current corrupted state
aws dynamodb create-backup \
  --table-name aws-service-monitor-registry \
  --backup-name pre-integrity-violation-backup-$(date +%Y%m%d-%H%M%S)

# 2. Get baseline services from S3 snapshot
SNAPSHOT=$(ls baseline-snapshots/ | sort -r | head -1)
cat baseline-snapshots/$SNAPSHOT | jq '.services' > baseline_services.json

# 3. Create Python script to restore
cat > restore_baseline.py << 'EOF'
import boto3
import json
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('aws-service-monitor-registry')

# Load expected services
with open('baseline_services.json', 'r') as f:
    services = json.load(f)

timestamp = datetime.utcnow().isoformat()

# Delete all service entries (except metadata)
scan = table.scan()
for item in scan['Items']:
    if not item['service_name'].startswith('__'):
        table.delete_item(Key={'service_name': item['service_name']})

# Restore baseline marker with original checksum
baseline_snapshot = json.load(open(f'baseline-snapshots/{services}'))
table.put_item(Item={
    'service_name': '__baseline_initialized__',
    'first_seen': timestamp,
    'status': 'initialized',
    'service_count': len(services),
    'checksum': baseline_snapshot['checksum']
})

# Restore all services
with table.batch_writer(batch_size=25) as batch:
    for service in services:
        batch.put_item(Item={
            'service_name': service,
            'first_seen': timestamp,
            'is_baseline': True
        })

print(f"Restored {len(services)} services")
EOF

# 4. Execute restore
python3 restore_baseline.py

# 5. Verify restoration
aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item | {checksum: .checksum.S, service_count: .service_count.N}'
```

### Step 9: Verify Recovery

```bash
# 1. Manually invoke Lambda to trigger integrity check
aws lambda invoke \
  --function-name aws-service-monitor \
  --payload '{}' \
  --region eu-west-2 \
  response.json

# 2. Check response
cat response.json | jq '.'

# 3. Verify alarm clears
aws cloudwatch describe-alarms \
  --alarm-names service-monitor-baseline-integrity-violation \
  --state-value ALARM

# Should return empty if alarm has cleared
```

---

## FORENSICS & ROOT CAUSE ANALYSIS (1-4 hours)

### Step 10: Document the Incident

**Create incident report with**:
- [ ] Date and time of violation detection
- [ ] Services/checksum affected
- [ ] Unauthorized principal (if identified from CloudTrail)
- [ ] Timeline of events from CloudTrail logs
- [ ] Actions taken to recover
- [ ] Impact assessment

```bash
# Generate CloudTrail report
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=aws-service-monitor-registry \
  --start-time $(date -d '24 hours ago' -Iseconds) \
  --output json > cloudtrail_events.json

echo "Saved CloudTrail events for investigation: cloudtrail_events.json"
```

### Step 11: Investigate Root Cause

**Questions to answer**:
1. **Who?** - Which IAM principal made modifications?
   ```bash
   jq '.Events[] | {UserIdentity: .UserIdentity.principalId, Event: .EventName}' cloudtrail_events.json
   ```

2. **Why?** - What was the motivation? (accidental/malicious)
   - Check if Lambda role was compromised
   - Verify no leaked credentials
   - Check for unauthorized IAM permission grants

3. **When?** - Timeline from first modification to detection
   - First modified: (from CloudTrail)
   - Detected: (from CloudWatch alarm)
   - Gap: (potential window for exploitation)

4. **Impact?** - Did SCP get updated with invalid services?
   ```bash
   # Check current SCP policy
   aws organizations describe-policy \
     --policy-id p-xxxxx \
     --content | jq '.Content | @json' | jq -r '.' | jq '.Statement[].Resource'
   ```

### Step 12: Preventive Actions

**Implement controls**:
- [ ] Review IAM policies for Lambda execution role
  - Ensure only necessary DynamoDB permissions
  - Restrict to specific table
  
- [ ] Enable CloudTrail for all DynamoDB API calls
  - Ensure S3 logging enabled
  - Log retention set to 90+ days

- [ ] Consider MFA delete on S3 immutable snapshots
  - Additional protection layer

- [ ] Monitor CloudTrail for suspicious patterns
  - Bulk DeleteItem operations
  - Unauthorized UpdateItem calls

- [ ] Review and restrict IAM access to:
  - DynamoDB table modifications
  - S3 snapshot access
  - CloudWatch alarm configuration

---

## ESCALATION

**If you cannot resolve**:
1. Contact AWS Support immediately (CRITICAL case)
   - Provide CloudTrail evidence
   - Provide backup/recovery timeline
   - Ask for forensics assistance

2. Escalate to Security Team
   - Potential credential compromise
   - Active security breach scenario
   - Legal/compliance implications

3. Escalate to Architecture Team
   - Design issues that enabled tampering
   - Additional security controls needed
   - Long-term mitigation strategy

---

## Related Documentation

- [Baseline Integrity T004](../threat-model/T004_IMPLEMENTATION.md)
- [Incident Response Guide](./INCIDENT_RESPONSE.md)
- [DynamoDB Recovery](./DYNAMODB_RECOVERY.md)
- [SECURITY.md](../SECURITY.md)

---

## Runbook Testing

**Last tested**: [Date]  
**Tested by**: [Name]  
**Result**: ✓ Passed / ✗ Failed

Test procedure:
1. Manually delete a service from DynamoDB
2. Manually invoke Lambda
3. Verify alarm fires and email sent
4. Execute recovery steps
5. Verify alarm clears
6. Cleanup

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24  
**Review Date**: 2026-05-24
