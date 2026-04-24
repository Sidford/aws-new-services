# Runbook: SCP Policy Rollback

**Severity**: CRITICAL  
**Response Time**: < 15 minutes  
**Runbook Owner**: Security/Platform Team

---

## When to Use This Runbook

- Service blacklist was updated with incorrect services
- Business critical services are now blocked
- SCP update caused service outages
- Need to reverse recent SCP changes

---

## Immediate Action (< 5 min)

### Step 1: Disable SCP Temporarily

**Option A**: Remove SCP attachment (FASTEST - 1 minute)
```bash
# List SCP attachments
aws organizations list-targets-for-policy \
  --policy-id p-xxxxxxxx \
  --region us-east-1

# Detach from root/targets
aws organizations detach-policy \
  --policy-id p-xxxxxxxx \
  --target-id r-xxxx \
  --region us-east-1

# Services now accessible again - emergency resolved
```

**Option B**: Update SCP to allow services temporarily (3 minutes)
```bash
# Get current policy
aws organizations describe-policy \
  --policy-id p-xxxxxxxx \
  --content \
  --region us-east-1 | jq '.Content | fromjson' > current-policy.json

# Edit to remove problematic services
vi current-policy.json
# Remove or comment out affected services from Resource list

# Update policy
aws organizations update-policy \
  --policy-id p-xxxxxxxx \
  --content file://current-policy.json \
  --region us-east-1
```

### Step 2: Notify Stakeholders
- [ ] Alert affected teams
- [ ] Confirm services are now accessible
- [ ] Create incident ticket
- [ ] Begin root cause analysis

---

## Root Cause Analysis (15 min)

### Step 3: Identify What Was Added

```bash
# Get current (incorrect) SCP
aws organizations describe-policy \
  --policy-id p-xxxxxxxx \
  --content \
  --region us-east-1 | jq '.Content | fromjson' > current-policy.json

# Get previous version from CloudTrail
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=p-xxxxxxxx \
  --lookup-attributes AttributeKey=EventName,AttributeValue=UpdatePolicy \
  --max-results 5 \
  --region us-east-1 | jq '.Events[0].CloudTrailEvent | fromjson'

# Extract policy from event and save
# Compare two policies to see what changed
diff previous-policy.json current-policy.json
```

### Step 4: Identify Root Cause

**Questions**:
1. Who created the update? (from CloudTrail)
2. What services were added incorrectly?
3. Why weren't they validated before update?
4. Did Lambda emit warnings in logs?

```bash
# Check Lambda logs for validation warnings
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "invalid\|failed validation\|ERROR" \
  --region us-east-1 \
  --start-time $(date -d '24 hours ago' +%s)000
```

---

## Recovery

### Step 5: Determine Correct SCP Content

**Option A**: Restore from previous version in CloudTrail
```bash
# Get last known good update before the problem
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=p-xxxxxxxx \
  --max-results 10 \
  | jq '.Events[] | select(.EventName == "UpdatePolicy") | {EventTime, CloudTrailEvent}' \
  | jq '.CloudTrailEvent | fromjson | .requestParameters.content' > previous-good-policy.json
```

**Option B**: Reconstruct from service registry
```bash
# Get current approved services from DynamoDB
python3 << 'EOF'
import boto3
import json

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('aws-service-monitor-registry')

# Scan for baseline services
response = table.scan(
    FilterExpression='#sn = :marker',
    ExpressionAttributeNames={'#sn': 'service_name'},
    ExpressionAttributeValues={':marker': '__baseline_initialized__'}
)

if response['Items']:
    baseline = response['Items'][0]
    print(f"Baseline services: {baseline.get('service_count', 'unknown')}")
    print(f"Checksum: {baseline.get('checksum', 'unknown')}")

# Get all tracked services
response = table.scan(
    FilterExpression='attribute_not_exists(service_name) OR NOT begins_with(service_name, :prefix)',
    ExpressionAttributeValues={':prefix': '__'},
    ProjectionExpression='service_name'
)

services = sorted([item['service_name'] for item in response['Items']])
print(f"\nTotal tracked services: {len(services)}")

# Build correct SCP
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Deny",
            "Action": "*",
            "Resource": [f"arn:aws:*:*:*:{service}/*" for service in services]
        }
    ]
}

with open('correct-policy.json', 'w') as f:
    json.dump(policy, f, indent=2)

print("\nWrote correct policy to correct-policy.json")
EOF
```

### Step 6: Apply Correct SCP

```bash
# Update policy with correct content
aws organizations update-policy \
  --policy-id p-xxxxxxxx \
  --content file://correct-policy.json \
  --region us-east-1

# Verify update
aws organizations describe-policy \
  --policy-id p-xxxxxxxx \
  --content \
  --region us-east-1 | jq '.Content | fromjson | .Statement[0].Resource | length'
```

---

## Validation

### Step 7: Verify Services Now Working

```bash
# Test critical service access
# Example: Try to create IAM role (if previously blocked)
aws iam get-role --role-name test-role 2>&1 | grep -i "deny\|not found"

# Should NOT see "Deny" error
```

### Step 8: Monitor for Issues

```bash
# Check CloudWatch Dashboard
# Look for any new errors after policy update
aws logs tail /aws/lambda/aws-service-monitor --format short --filter-pattern ERROR
```

---

## Prevention

### Update SCP Update Process

1. **Always use REQUIRE_APPROVAL = true**
   - Prevents auto-update
   - Allows manual review
   - Requires explicit approval

2. **Implement change control**
   - Document why services were added
   - Get second opinion on SCP changes
   - Test in non-prod first (if available)

3. **Add more validation**
   - DynamoDB: Only add services that exist in baseline
   - Cross-check service names with AWS docs
   - Limit service additions to batch review period

---

## Related

- [Baseline Integrity](./BASELINE_INTEGRITY_VIOLATION.md)
- [Incident Response](./INCIDENT_RESPONSE.md)
- [Lambda Validation](../lambda/)

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24  
**Review Date**: 2026-05-24
