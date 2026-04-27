# Runbook: Service Registry Cleanup

**Severity**: LOW  
**Response Time**: < 2 hours  
**Runbook Owner**: Platform Team

---

## When to Use

- Service names changed in AWS (e.g., rds → rds-expanded)
- Duplicate services in registry
- Stale/deprecated services to remove
- Maintain registry hygiene

---

## Safe Cleanup Process

### Step 1: Identify Candidates

```bash
# Services not updated recently
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --filter-expression "attribute_not_exists(#sn) OR NOT begins_with(#sn, :prefix)" \
  --expression-attribute-names '{"#sn":"service_name"}' \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  --projection-expression 'service_name,first_seen' \
  | jq '.Items[] | select(.first_seen.S | . < "2024-01-01") | .service_name.S' \
  > stale_candidates.txt

# Duplicates
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --projection-expression 'service_name' \
  | jq '.Items[].service_name.S' | sort | uniq -d \
  > duplicate_candidates.txt

# Invalid names (should match: ^[a-z0-9\-]+$)
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --projection-expression 'service_name' \
  | jq '.Items[] | select(.service_name.S | test("[^a-z0-9\\-]")) | .service_name.S' \
  > invalid_candidates.txt
```

### Step 2: Validate Against Current Services

```bash
# Get current AWS services
curl -s https://servicereference.eu-west-2.amazonaws.com/ | jq '.services | keys' > current_services.json

# Check which candidates are in current AWS services
cat stale_candidates.txt | while read service; do
  if grep -q "\"$service\"" current_services.json; then
    echo "$service STILL VALID"
  else
    echo "$service DEPRECATED"
  fi
done
```

### Step 3: Create Removal Approval List

```bash
# Build list of approved-for-deletion services
# Only include services that are:
# 1. NOT in current AWS services
# 2. Verified as safe to remove
# 3. Approved by team

cat > services_to_delete.txt << 'EOF'
old-service-1
old-service-2
deprecated-service
EOF
```

### Step 4: Backup Before Deletion

```bash
# Always backup
aws dynamodb create-backup \
  --table-name aws-service-monitor-registry \
  --backup-name pre-cleanup-backup-$(date +%Y%m%d-%H%M%S)

# Export data
aws dynamodb export-table-to-point-in-time \
  --table-arn arn:aws:dynamodb:eu-west-2:ACCOUNT:table/aws-service-monitor-registry \
  --s3-bucket my-backup-bucket \
  --s3-prefix cleanup-export-$(date +%Y%m%d-%H%M%S) \
  --export-format JSON
```

### Step 5: Delete Services

```bash
# Delete approved services
cat services_to_delete.txt | while read service; do
  echo "Deleting: $service"
  aws dynamodb delete-item \
    --table-name aws-service-monitor-registry \
    --key "{\"service_name\":{\"S\":\"$service\"}}" \
    --region eu-west-2
done
```

### Step 6: Update Baseline Checksum

```bash
# Important: If any services deleted, baseline integrity will fail!
# Must update baseline checksum to reflect new service list

python3 << 'EOF'
import boto3
import json
import hashlib

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('aws-service-monitor-registry')

# Get all services (excluding metadata)
response = table.scan(
    FilterExpression='attribute_not_exists(service_name) OR NOT begins_with(service_name, :prefix)',
    ExpressionAttributeValues={':prefix': '__'},
    ProjectionExpression='service_name'
)

services = sorted([item['service_name'] for item in response['Items']])

# Calculate new checksum
service_string = json.dumps(services, separators=(',', ':'))
new_checksum = hashlib.sha256(service_string.encode()).hexdigest()

# Update baseline marker with new checksum
table.update_item(
    Key={'service_name': '__baseline_initialized__'},
    UpdateExpression='SET #check = :check',
    ExpressionAttributeNames={'#check': 'checksum'},
    ExpressionAttributeValues={':check': new_checksum}
)

print(f"Cleaned {len(services)} valid services")
print(f"New checksum: {new_checksum}")
EOF
```

### Step 7: Verify Baseline Integrity

```bash
# Run Lambda to verify integrity check passes
aws lambda invoke \
  --function-name aws-service-monitor \
  --payload '{}' \
  --region eu-west-2 \
  verify-response.json

cat verify-response.json | jq '.'

# Should show "Baseline integrity verified"
```

---

## Verification

```bash
# Check service count decreased
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --select COUNT \
  --filter-expression "NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  | jq '.Count'

# Verify no integrity alarms
aws cloudwatch describe-alarms \
  --alarm-names service-monitor-baseline-integrity-violation \
  --state-value ALARM

# Should be empty
```

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24
