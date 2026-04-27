# Baseline Initialization Guide

## Overview

When the AWS Service Monitor is first deployed, it automatically initializes a baseline with all current AWS services. This prevents false positives on the first run and ensures accurate detection of new services going forward.

## How It Works

### First Run: Baseline Initialization

```
EventBridge Trigger
         ↓
Lambda Function Starts
         ↓
Fetch AWS Services (e.g., 234 services)
         ↓
Check if Baseline Exists? NO
         ↓
Initialize Baseline
  - Store all 234 services in DynamoDB
  - Mark baseline as initialized
  - No SCP updates
  - No emails sent
         ↓
Return: "Baseline established"
```

### Subsequent Runs: Normal Monitoring

```
EventBridge Trigger
         ↓
Lambda Function Starts
         ↓
Fetch AWS Services (e.g., 235 services)
         ↓
Check if Baseline Exists? YES
         ↓
Get Tracked Services (234)
         ↓
Calculate Difference (235 - 234 = 1 new)
         ↓
IF new services:
  - Validate service names
  - Update SCP (with approval workflow)
  - Send email notification
  - Update DynamoDB registry
         ↓
Return: "Processed 1 new service"
```

## Baseline State in DynamoDB

### Baseline Marker Entry
```json
{
  "service_name": "__baseline_initialized__",
  "first_seen": "2026-04-24T12:00:00.000000",
  "last_updated": "2026-04-24T12:00:00.000000",
  "status": "initialized",
  "service_count": 234
}
```

### Service Entries (Baseline)
```json
{
  "service_name": "acm",
  "first_seen": "2026-04-24T12:00:00.000000",
  "last_updated": "2026-04-24T12:00:00.000000",
  "is_baseline": true
}
```

## First Run Response

### Success Response
```json
{
  "statusCode": 200,
  "body": {
    "message": "Baseline established",
    "baseline_services": 234,
    "status": "baseline_initialized",
    "note": "No actions taken on first run. Monitoring will begin on next execution.",
    "scan_time": "2026-04-24T12:00:00.000000"
  }
}
```

### Error Response
```json
{
  "statusCode": 500,
  "body": {
    "error": "Failed to initialize baseline",
    "scan_time": "2026-04-24T12:00:00.000000"
  }
}
```

## Why This Approach?

### ✅ Benefits

1. **Prevents False Positives**
   - All existing services are not treated as "new"
   - No unnecessary emails on first deployment
   - No accidental SCP changes on day one

2. **Clean Audit Trail**
   - Clear separation between baseline and new services
   - Easy to identify when monitoring started
   - Timestamp shows initialization date

3. **Safe First Deployment**
   - Can deploy with confidence
   - No disruption to organization policies
   - Allows time to verify deployment is working

4. **Baseline Verification**
   - Can check DynamoDB to see what baseline contains
   - Can verify count matches AWS service reference
   - Can recover baseline if needed

### 🚀 Deployment Timeline

```
Day 1 (Deployment)
├─ Deploy Terraform configuration
├─ Lambda first run at 8 AM UTC
├─ Baseline established (234 services)
├─ No SCP changes
└─ No emails sent

Day 2 onwards
├─ Lambda runs daily at 8 AM UTC
├─ Compares against baseline
├─ Alerts if new services found
├─ Sends emails
└─ Updates SCP (with approval)
```

## Verifying Baseline Initialization

### Check if Baseline Exists

```bash
aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  --region eu-west-2
```

Expected output:
```json
{
  "Item": {
    "service_name": {"S": "__baseline_initialized__"},
    "status": {"S": "initialized"},
    "service_count": {"N": "234"},
    "first_seen": {"S": "2026-04-24T12:00:00.000000"},
    "last_updated": {"S": "2026-04-24T12:00:00.000000"}
  }
}
```

### Count Baseline Services

```bash
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --filter-expression "attribute_exists(is_baseline)" \
  --select COUNT \
  --region eu-west-2
```

### List All Baseline Services

```bash
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --filter-expression "is_baseline = :b" \
  --expression-attribute-values '{":b":{"BOOL":true}}' \
  --projection-expression "service_name" \
  --region eu-west-2
```

## Resetting Baseline (If Needed)

If you need to reset the baseline and reinitialize:

### Option 1: Clear DynamoDB Table
```bash
# Delete all items
aws dynamodb delete-table \
  --table-name aws-service-monitor-registry \
  --region eu-west-2

# Wait for deletion (about 30 seconds)
sleep 30

# Recreate via Terraform
terraform apply
```

### Option 2: Delete Just Baseline Marker
```bash
# Remove baseline marker (table will rebuild on next run)
aws dynamodb delete-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  --region eu-west-2

# Next Lambda run will reinitialize baseline
```

### Option 3: Selective Reset
```bash
# Keep only baseline marker (delete all services)
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --projection-expression "service_name" \
  --region eu-west-2 | jq -r '.Items[] | select(.service_name.S != "__baseline_initialized__") | .service_name.S' | \
  while read service; do
    aws dynamodb delete-item \
      --table-name aws-service-monitor-registry \
      --key "{\"service_name\":{\"S\":\"$service\"}}" \
      --region eu-west-2
  done
```

## Lambda Logs on First Run

Check CloudWatch logs to verify baseline initialization:

```bash
aws logs tail /aws/lambda/aws-service-monitor --follow
```

Expected log output:
```
[INFO] Starting AWS service monitor at 2026-04-24T12:00:00.000000
[INFO] Fetched 234 services from AWS reference
[INFO] Total services: 234
[INFO] === BASELINE INITIALIZATION ===
[INFO] First run detected - initializing baseline
[INFO] Baseline initialized with 234 services
```

## Subsequent Run Logs

```bash
aws logs tail /aws/lambda/aws-service-monitor --follow
```

Expected log output (if no new services):
```
[INFO] Starting AWS service monitor at 2026-04-25T08:00:00.000000
[INFO] Fetched 234 services from AWS reference
[INFO] Total services: 234
[INFO] Retrieved 234 tracked services from DynamoDB
[INFO] New services: 0
[INFO] No new services detected
```

Expected log output (if new services):
```
[INFO] Starting AWS service monitor at 2026-04-25T08:00:00.000000
[INFO] Fetched 235 services from AWS reference
[INFO] Total services: 235
[INFO] Retrieved 234 tracked services from DynamoDB
[INFO] New services: 1
[INFO] Found services: ['new-service']
[INFO] Successfully updated SCP with 1 new services
[INFO] Sent email notification to 2 recipient(s)
```

## FAQ

### Q: What if the first run fails?
**A**: The baseline will not be initialized. On the next run, it will retry initialization. Check logs for errors.

### Q: Can I manually trigger baseline on an already-initialized deployment?
**A**: No, the code checks if baseline exists first. To reinitialize, delete the baseline marker from DynamoDB (see Resetting Baseline section).

### Q: Does baseline get updated over time?
**A**: No, baseline is static. New services are tracked separately. The baseline serves as the reference point for what services existed at initialization time.

### Q: What if AWS adds 50 new services at once?
**A**: All 50 will be detected as new on the next run and handled according to the approval workflow.

### Q: Can I see what was in the baseline?
**A**: Yes, scan the DynamoDB table with `is_baseline = true` filter. See "Verifying Baseline Initialization" section.

### Q: What if I deploy on a different account later?
**A**: Each account has its own DynamoDB table, so each will initialize its own baseline independently.

### Q: Can baseline be reinitialized if I accidentally delete it?
**A**: Yes, delete the `__baseline_initialized__` marker from DynamoDB and trigger Lambda again. It will reinitialize baseline with current services.

## Troubleshooting

### Baseline Not Initializing

```bash
# Check Lambda logs
aws logs tail /aws/lambda/aws-service-monitor --follow --filter-pattern "BASELINE"

# Check DynamoDB table exists
aws dynamodb describe-table \
  --table-name aws-service-monitor-registry \
  --region eu-west-2

# Check Lambda IAM permissions
aws iam get-role-policy \
  --role-name aws-service-monitor-lambda-role \
  --policy-name lambda-dynamodb-policy
```

### Service Count Mismatch

If baseline service count doesn't match AWS reference:

```bash
# Get baseline count
BASELINE=$(aws dynamodb get-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  --region eu-west-2 | jq -r '.Item.service_count.N')

echo "Baseline: $BASELINE services"

# Manually trigger Lambda and check response
aws lambda invoke \
  --function-name aws-service-monitor \
  response.json

cat response.json | jq '.body' | jq '.baseline_services // .message'
```

## Next Steps

1. **Deploy the solution** - Baseline will initialize on first run
2. **Verify initialization** - Check DynamoDB or CloudWatch logs
3. **Wait 24 hours** - Or manually trigger for next run
4. **Monitor for new services** - Emails and SCP updates will begin on subsequent runs
5. **Review logs** - Check CloudWatch for execution details

See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for full deployment instructions.
