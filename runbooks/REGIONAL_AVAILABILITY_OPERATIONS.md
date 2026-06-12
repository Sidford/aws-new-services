# Regional Availability Operations Runbook

**Document Version**: 1.0  
**Last Updated**: 2026-06-11  
**Audience**: DevOps, Security, Infrastructure Teams

---

## Overview

This runbook covers operational procedures for managing AWS services that are detected globally but not yet available in your target region (eu-west-2). The system uses a **zero-trust, cautious-by-default** approach:

- **Immediate Protection**: All new services are added to SCP blacklist immediately
- **Regional Intelligence**: Daily monitoring tracks when services become available in your region
- **Proactive Planning**: Notifications enable cost planning and operational readiness

---

## Table of Contents

1. [Monitoring Pending Services](#monitoring-pending-services)
2. [Understanding Service States](#understanding-service-states)
3. [Common Operational Tasks](#common-operational-tasks)
4. [Troubleshooting](#troubleshooting)
5. [Quick Reference](#quick-reference)

---

## Monitoring Pending Services

### Overview Dashboard

View all pending services in your monitored region:

```bash
# List all services currently pending availability in eu-west-2
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :region AND available_in_region = :available' \
  --expression-attribute-values '{
    ":region":{"S":"eu-west-2"},
    ":available":{"N":"0"}
  }' \
  --region eu-west-2 \
  --output table
```

**Output columns**:
- `service_name`: Service identifier
- `first_detected_at`: When service was detected globally
- `last_checked_at`: Most recent availability check
- `region_name`: Target region (eu-west-2)

### Service Status Details

Get detailed status for a specific pending service:

```bash
SERVICE_NAME="bedrock-agents"
DETECTED_AT="2026-06-11T08:15:33Z"

aws dynamodb get-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{
    "service_name":{"S":"'$SERVICE_NAME'"},
    "detected_at":{"S":"'$DETECTED_AT'"}
  }' \
  --region eu-west-2 \
  --output json | jq '.'
```

### Check Last Monitoring Run

View when pending services were last checked:

```bash
# Query and sort by last check time
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :region AND available_in_region = :available' \
  --expression-attribute-values '{
    ":region":{"S":"eu-west-2"},
    ":available":{"N":"0"}
  }' \
  --region eu-west-2 \
  --projection-expression 'service_name, last_checked_at' | \
  jq '.Items | sort_by(.last_checked_at.S) | reverse | .[] | "\(.service_name.S): \(.last_checked_at.S)"'
```

---

## Understanding Service States

### Service State Machine

```
┌─────────────────────────────────────────────────────┐
│ New Service Detected Globally (AWS Announces)      │
└──────────────────┬──────────────────────────────────┘
                   │
                   ├─→ STORED in service_registry (DynamoDB)
                   ├─→ ADDED to SCP blacklist immediately ✅
                   │
                   └──→ Regional Availability Check
                       │
                       ├─→ Available in eu-west-2
                       │   └─→ Email shows "Available now"
                       │
                       └─→ NOT available in eu-west-2
                           └─→ Added to pending_regional_services table
                               └─→ Email shows "Pending eu-west-2 deployment"
                                   └─→ Daily monitoring begins

┌────────────────────────────────────────────────────┐
│ Daily Monitoring (check_pending_regional_services) │
└────────────┬─────────────────────────────────────────┘
             │
             ├─→ Service still NOT available
             │   └─→ Update last_checked_at
             │   └─→ Continue monitoring
             │
             ├─→ Service NOW available
             │   └─→ Update available_in_region = true
             │   └─→ Set available_at timestamp
             │   └─→ Send notification email ✉️
             │   └─→ Email: "Service Now Available in eu-west-2"
             │
             └─→ Service delisted from global AWS
                 └─→ Archive record (status='archived')
                 └─→ Stop monitoring
```

### Table Schema Reference

**`pending_regional_services` Table**

| Field | Type | Meaning |
|-------|------|---------|
| `service_name` (PK) | String | AWS service name (e.g., "bedrock-agents") |
| `detected_at` (SK) | String | ISO timestamp when service was detected |
| `first_detected_at` | String | Initial detection time (same as detected_at) |
| `region_name` | String | Monitored region (e.g., "eu-west-2") |
| `available_in_region` | Number | 0=not available, 1=available (used by GSI) |
| `last_checked_at` | String | Most recent availability check timestamp |
| `available_at` | String | When service became available in region |
| `notification_sent` | Boolean | Whether "now available" email was sent |

**Example Record (Pending)**:
```json
{
  "service_name": {"S": "bedrock-agents"},
  "detected_at": {"S": "2026-06-11T08:15:33Z"},
  "first_detected_at": {"S": "2026-06-11T08:15:33Z"},
  "region_name": {"S": "eu-west-2"},
  "available_in_region": {"N": "0"},
  "last_checked_at": {"S": "2026-06-12T08:15:33Z"},
  "notification_sent": {"BOOL": false}
}
```

**Example Record (Now Available)**:
```json
{
  "service_name": {"S": "bedrock-agents"},
  "detected_at": {"S": "2026-06-11T08:15:33Z"},
  "available_in_region": {"N": "1"},
  "available_at": {"S": "2026-06-26T10:30:45Z"},
  "notification_sent": {"BOOL": true}
}
```

---

## Common Operational Tasks

### Task 1: View All Pending Services with Ages

Check how long services have been pending:

```bash
#!/bin/bash
# Script to show pending services and how long they've been pending

NOW=$(date -u +%s)

aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :region AND available_in_region = :available' \
  --expression-attribute-values '{
    ":region":{"S":"eu-west-2"},
    ":available":{"N":"0"}
  }' \
  --region eu-west-2 \
  --output json | jq -r '.Items[] | 
    "\(.service_name.S),\(.first_detected_at.S),\(.last_checked_at.S)"' | \
  while IFS=',' read service detected checked; do
    DETECTED_TS=$(date -d "$detected" +%s)
    DAYS_PENDING=$(( ($NOW - $DETECTED_TS) / 86400 ))
    printf "%-40s Pending: %3d days  (detected: %s)\n" \
      "$service" "$DAYS_PENDING" "$detected"
  done
```

### Task 2: Monitor a Specific Service

Track a single service's journey to regional availability:

```bash
SERVICE_NAME="sagemaker-canvas"

# Query all records for this service (may have multiple detected_at timestamps)
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --key-condition-expression 'service_name = :svc' \
  --expression-attribute-values '{
    ":svc":{"S":"'$SERVICE_NAME'"}
  }' \
  --region eu-west-2 \
  --output json | jq '.Items[] | {
    service: .service_name.S,
    detected: .first_detected_at.S,
    available_in_region: (.available_in_region.N | tonumber),
    last_checked: .last_checked_at.S,
    available_at: .available_at.S,
    notified: .notification_sent.BOOL
  }'
```

### Task 3: Manually Trigger Regional Availability Check

Force an immediate check instead of waiting for daily Lambda run:

```bash
# Invoke Lambda function immediately
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  /tmp/lambda_response.json

# Check output
jq '.' /tmp/lambda_response.json

# Check logs for regional monitoring activity
aws logs tail /aws/lambda/aws-service-monitor \
  --region eu-west-2 \
  --follow \
  --since 1m | grep -i regional
```

### Task 4: Archive a Pending Service (Manual Removal)

Stop monitoring a service that will never be needed:

```bash
SERVICE_NAME="old-service-to-ignore"
DETECTED_AT="2026-06-11T08:15:33Z"

# Update the record to archived status
aws dynamodb update-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{
    "service_name":{"S":"'$SERVICE_NAME'"},
    "detected_at":{"S":"'$DETECTED_AT'"}
  }' \
  --update-expression 'SET #status = :archived, archived_at = :ts' \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{
    ":archived":{"S":"archived"},
    ":ts":{"S":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}
  }' \
  --region eu-west-2

echo "Service archived - monitoring stopped"
```

### Task 5: Check Regional Monitoring Activity in Logs

View what happened during the last Lambda run:

```bash
# Show all regional monitoring activity from last 24 hours
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "[..., msg, ...]" \
  --region eu-west-2 \
  --start-time $(($(date +%s) - 86400))000 | \
  jq -r '.events[] | select(.message | contains("PENDING REGIONAL") or contains("available in")) | .message'

# Example output:
# INFO: === CHECKING PENDING REGIONAL SERVICES ===
# INFO: Checking 5 pending services for regional availability
# INFO: Service bedrock-agents is now available in eu-west-2
# INFO: Sent regional availability notification for bedrock-agents
```

### Task 6: Compare Services Across Regions

Check which services are available in multiple regions:

```bash
# List all pending services for each region
for REGION in eu-west-2 us-east-1 us-west-2 ap-southeast-1; do
  echo "=== Pending in $REGION ==="
  aws dynamodb query \
    --table-name aws-service-monitor-pending-regional \
    --index-name region-name-index \
    --key-condition-expression 'region_name = :region AND available_in_region = :available' \
    --expression-attribute-values '{
      ":region":{"S":"'$REGION'"},
      ":available":{"N":"0"}
    }' \
    --region eu-west-2 \
    --projection-expression 'service_name' | \
    jq -r '.Items[].service_name.S'
done
```

### Task 7: Export Pending Services Report

Generate a CSV report for analysis:

```bash
# Export all pending services to CSV
{
  echo "service_name,first_detected_at,days_pending,region,status"
  
  NOW=$(date +%s)
  
  aws dynamodb query \
    --table-name aws-service-monitor-pending-regional \
    --index-name region-name-index \
    --key-condition-expression 'region_name = :region AND available_in_region = :available' \
    --expression-attribute-values '{
      ":region":{"S":"eu-west-2"},
      ":available":{"N":"0"}
    }' \
    --region eu-west-2 \
    --output json | jq -r '.Items[] |
      "\(.service_name.S),\(.first_detected_at.S),\(($NOW - ((.first_detected_at.S | fromdateiso8601))) / 86400 | floor),\(.region_name.S),pending"'
} > pending_services_$(date +%Y%m%d).csv

echo "Report saved to pending_services_$(date +%Y%m%d).csv"
```

---

## Troubleshooting

### Issue 1: Services Not Being Tracked as Pending

**Symptom**: New services detected but not appearing in pending table

**Root Cause Checklist**:
1. Regional monitoring disabled: `ENABLE_REGIONAL_MONITORING = "false"`
2. Services are actually available in all regions
3. Lambda permissions missing for `pending_regional_services` table
4. Pending table doesn't exist

**Diagnosis**:
```bash
# Check Lambda environment
aws lambda get-function-configuration \
  --function-name aws-service-monitor \
  --query 'Environment.Variables.ENABLE_REGIONAL_MONITORING' \
  --region eu-west-2

# Check table exists
aws dynamodb describe-table \
  --table-name aws-service-monitor-pending-regional \
  --region eu-west-2

# Check Lambda logs for errors
aws logs tail /aws/lambda/aws-service-monitor --follow --since 10m
```

**Resolution**:
```bash
# Enable regional monitoring (if disabled)
aws lambda update-function-configuration \
  --function-name aws-service-monitor \
  --environment 'Variables={ENABLE_REGIONAL_MONITORING=true}' \
  --region eu-west-2

# Or re-deploy with Terraform
terraform apply -var-file=terraform.tfvars
```

### Issue 2: Regional Availability Notification Not Sent

**Symptom**: Service becomes available in region but no email received

**Root Cause Checklist**:
1. Email addresses not verified in SES
2. SES account in sandbox mode
3. Service is not actually available (false positive)
4. Notification already sent (duplicate check working correctly)
5. Lambda Lambda IAM permissions issue

**Diagnosis**:
```bash
# Check SES verified identities
aws ses list-identities --region eu-west-2

# Check SES sending limits (sandbox vs. production)
aws ses get-account-sending-enabled --region eu-west-2

# Check Lambda logs for send errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "Error sending email" \
  --region eu-west-2

# Check if service is actually marked as available
SERVICE_NAME="bedrock-agents"
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --key-condition-expression 'service_name = :svc' \
  --expression-attribute-values '{":svc":{"S":"'$SERVICE_NAME'"}}' \
  --region eu-west-2 | jq '.Items[] | {available: .available_in_region.N, notified: .notification_sent.BOOL}'
```

**Resolution**:
```bash
# If in SES sandbox, request production access
aws ses request-production-access \
  --region eu-west-2 \
  --additional-emails "team@example.com"

# Or verify all recipients
aws ses verify-email-identity \
  --email-address recipient@example.com \
  --region eu-west-2

# Manually resend notification if missed
aws lambda invoke \
  --function-name send-regional-notification \
  --payload '{"service_name":"bedrock-agents","timestamp":"2026-06-26T08:15:33Z"}' \
  /tmp/response.json \
  --region eu-west-2
```

### Issue 3: Stale Pending Records

**Symptom**: Services remain in pending table long after becoming available elsewhere

**Root Cause**: 
- Regional availability check failing silently
- DynamoDB update failures
- Service available in other regions but not target region

**Diagnosis**:
```bash
# Check when services were last checked
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :region AND available_in_region = :available' \
  --expression-attribute-values '{
    ":region":{"S":"eu-west-2"},
    ":available":{"N":"0"}
  }' \
  --region eu-west-2 \
  --projection-expression 'service_name, last_checked_at' | \
  jq '.Items[] | select((.last_checked_at.S | fromdateiso8601) < (now - 604800))'  # > 7 days old
```

**Resolution**: Manually archive old pending services

```bash
SERVICE_NAME="very-old-service"
DETECTED_AT="2026-06-11T08:15:33Z"

aws dynamodb update-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{
    "service_name":{"S":"'$SERVICE_NAME'"},
    "detected_at":{"S":"'$DETECTED_AT'"}
  }' \
  --update-expression 'SET #status = :archived, archived_reason = :reason, archived_at = :ts' \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{
    ":archived":{"S":"archived"},
    ":reason":{"S":"stale_pending_manual_archive"},
    ":ts":{"S":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}
  }' \
  --region eu-west-2
```

### Issue 4: High DynamoDB Costs from Regional Monitoring

**Symptom**: Unexpected charges from pending_regional_services table

**Cause**: Frequent queries or scans of the table

**Diagnosis**:
```bash
# Check CloudWatch metrics for the table
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedWriteCapacityUnits \
  --dimensions Name=TableName,Value=aws-service-monitor-pending-regional \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 \
  --statistics Sum \
  --region eu-west-2
```

**Resolution**:
1. Ensure queries use GSI (not table scan)
2. Archive old pending services to reduce table size
3. Consider adjusting Lambda run frequency if running too often

---

## Quick Reference

### Essential Commands

```bash
# View all pending services
aws dynamodb query --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :r AND available_in_region = :a' \
  --expression-attribute-values '{":r":{"S":"eu-west-2"},":a":{"N":"0"}}' \
  --region eu-west-2

# Check specific service status
aws dynamodb get-item --table-name aws-service-monitor-pending-regional \
  --key '{"service_name":{"S":"SERVICE_NAME"},"detected_at":{"S":"TIMESTAMP"}}' \
  --region eu-west-2

# Archive a service
aws dynamodb update-item --table-name aws-service-monitor-pending-regional \
  --key '{"service_name":{"S":"SERVICE_NAME"},"detected_at":{"S":"TIMESTAMP"}}' \
  --update-expression 'SET #status = :archived' \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":archived":{"S":"archived"}}' \
  --region eu-west-2

# Trigger immediate check
aws lambda invoke --function-name aws-service-monitor --region eu-west-2 /tmp/out.json

# View logs
aws logs tail /aws/lambda/aws-service-monitor --follow --region eu-west-2
```

### Log Search Patterns

```bash
# Regional monitoring activity
aws logs filter-log-events --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "CHECKING PENDING REGIONAL" --region eu-west-2

# Services now available
aws logs filter-log-events --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "now available in" --region eu-west-2

# Regional monitoring errors
aws logs filter-log-events --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "Error checking regional" --region eu-west-2
```

### Metrics to Monitor

**CloudWatch Dashboard Recommendations**:

```hcl
# Add these widgets to your CloudWatch dashboard
widget "pending_services_count" {
  metric = "aws-service-monitor/PendingServices"
  stat = "Average"
  period = 3600
}

widget "services_now_available" {
  metric = "aws-service-monitor/ServicesNowAvailable"
  stat = "Sum"
  period = 86400
}

widget "regional_check_failures" {
  metric = "aws-service-monitor/RegionalCheckErrors"
  stat = "Sum"
  period = 3600
}
```

### Alert Thresholds

**Recommended CloudWatch Alarms**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Services Pending > 30 days | Count >= 5 | Alert to ops team |
| Regional Check Errors | Count > 0 | Alert to DevOps |
| Email Notification Failures | Count > 2 | Alert immediately |

---

## Related Documentation

- [Regional Availability Monitoring](../DEVELOPMENT.md#regional-availability-monitoring) - Development guide
- [Architecture](../ARCHITECTURE.md) - System design
- [Deployment Guide](../DEPLOYMENT_GUIDE.md) - Initial setup
