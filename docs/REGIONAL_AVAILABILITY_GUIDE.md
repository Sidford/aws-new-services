# Regional Availability Monitoring - Quick Reference Guide

**Short URL**: For all things regional monitoring, see this guide.

---

## What It Is

The system monitors new AWS services to determine when they become available in your target region (**eu-west-2**). This provides:

- **Early Intelligence**: Know what AWS is building before formal announcements
- **Market Awareness**: Track regional rollout patterns across AWS
- **Operational Planning**: Prepare for new service adoption with advance notice
- **Cost Planning**: Understand service availability timeline before it hits your region

---

## Zero-Trust Approach

```
All New Services → ✅ IMMEDIATELY Added to SCP Blacklist
                 → Check Regional Availability (intelligence only)
                 → Track pending services in DynamoDB
                 → Daily monitoring for when they arrive
```

**Key**: Regional availability does **NOT** gate SCP updates. Services are protected from day one.

---

## Quick Facts

| Aspect | Details |
|--------|---------|
| **How often checked** | Daily (same schedule as main Lambda) |
| **Monitored region** | eu-west-2 (hardcoded, can be customized) |
| **Data storage** | `aws-service-monitor-pending-regional` DynamoDB table |
| **Cost impact** | <$1/month (on-demand DynamoDB) |
| **Performance impact** | ~5-10 seconds per run (minimal) |
| **Enable/disable** | Set `ENABLE_REGIONAL_MONITORING = "true"/"false"` |
| **Email notifications** | 2 types: detection (immediate) + now available (later) |

---

## Email Examples

### Email 1: Service Detected
```
Subject: AWS Service Monitor: 3 New Service(s) Detected

New AWS Services Detected
Detected at: 2026-06-11 08:15:33 UTC

SCP Status: ✅ Added to blacklist
All new services have been IMMEDIATELY added to the SCP.

Regional Status (eu-west-2):
  Available in eu-west-2: 2/3
  Pending eu-west-2 deployment: 1/3
  
Monitoring: Services not yet available in eu-west-2 will be tracked daily.
You will be notified when they become available.

New Services:
  - bedrock-agents (Available now)
  - sagemaker-canvas (Pending eu-west-2)
  - transcribe-streaming (Available now)
```

### Email 2: Service Now Available (sent later)
```
Subject: ✅ AWS Service Now Available in eu-west-2: sagemaker-canvas

Service Now Available in Region: eu-west-2

sagemaker-canvas is now available in your region.

Status: Service is already protected by SCP (added on detection date)
Date Available: 2026-06-26 10:30:45 UTC

This is for cost tracking and operational planning purposes.
No SCP changes are needed - the service has been blocked since first detection.
```

---

## Common Tasks

### View All Pending Services
```bash
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :r AND available_in_region = :a' \
  --expression-attribute-values '{
    ":r":{"S":"eu-west-2"},
    ":a":{"N":"0"}
  }' \
  --region eu-west-2 \
  --output table
```

### Check Specific Service Status
```bash
SERVICE="bedrock-agents"
DETECTED="2026-06-11T08:15:33Z"

aws dynamodb get-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{
    "service_name":{"S":"'$SERVICE'"},
    "detected_at":{"S":"'$DETECTED'"}
  }' \
  --region eu-west-2
```

### Force Immediate Check
```bash
# Trigger Lambda immediately instead of waiting for daily run
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  /tmp/response.json

# Check logs
aws logs tail /aws/lambda/aws-service-monitor --follow --region eu-west-2
```

### Stop Monitoring a Service
```bash
SERVICE="old-service"
DETECTED="2026-06-11T08:15:33Z"

aws dynamodb update-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{
    "service_name":{"S":"'$SERVICE'"},
    "detected_at":{"S":"'$DETECTED'"}
  }' \
  --update-expression 'SET #status = :archived' \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":archived":{"S":"archived"}}' \
  --region eu-west-2
```

---

## Configuration

### Enable/Disable in Lambda
```python
# Set via Terraform environment variables:
ENABLE_REGIONAL_MONITORING = "true"    # Set to "false" to disable
MONITORED_REGION = "eu-west-2"         # Can be changed to any region
```

### Current Settings
Check your Lambda configuration:
```bash
aws lambda get-function-configuration \
  --function-name aws-service-monitor \
  --region eu-west-2 | jq '.Environment.Variables | 
    {ENABLE_REGIONAL_MONITORING, MONITORED_REGION}'
```

---

## Data Schema

**`pending_regional_services` DynamoDB Table**:

| Column | Type | Purpose |
|--------|------|---------|
| `service_name` (PK) | String | Service ID (e.g., "bedrock-agents") |
| `detected_at` (SK) | String | When service was detected |
| `first_detected_at` | String | Initial detection time |
| `region_name` | String | Monitored region |
| `available_in_region` | Number | 0=pending, 1=available |
| `last_checked_at` | String | Most recent check time |
| `available_at` | String | When it became available |
| `notification_sent` | Boolean | "Now available" email sent? |

**Service Flow**:
```
[Detected] → available_in_region=0
           → last_checked_at updated daily
           ↓
        [Available] → available_in_region=1
                    → available_at set
                    → notification_sent=true
```

---

## Troubleshooting

### Q: Services not being tracked as pending
**Check**:
1. Is `ENABLE_REGIONAL_MONITORING = "true"`?
2. Check Lambda logs: `aws logs tail /aws/lambda/aws-service-monitor --follow`
3. Does table exist? `aws dynamodb describe-table --table-name aws-service-monitor-pending-regional`

**Fix**: Re-deploy with `terraform apply`

---

### Q: "Now available" email not sent
**Check**:
1. Is service actually marked as available? 
   ```bash
   aws dynamodb get-item --table-name aws-service-monitor-pending-regional \
     --key '{"service_name":{"S":"service-name"},"detected_at":{"S":"timestamp"}}'
   ```
2. Are email addresses verified in SES?
   ```bash
   aws ses list-identities --region eu-west-2
   ```
3. Check logs: `aws logs filter-log-events --log-group-name /aws/lambda/aws-service-monitor --filter-pattern "Error sending email"`

**Fix**: Verify emails in SES or re-deploy

---

### Q: Services pending for months
**Check**: Are they actually unavailable in eu-west-2?

If service is legitimately not available, that's correct behavior. If AWS added it to the region but check failed:

```bash
# Manually check one service
aws lambda invoke --function-name aws-service-monitor /tmp/r.json
```

---

## Monitoring Metrics

**CloudWatch Metrics** (automatically published):
- `PendingServices` — Count of services pending regional availability
- `ServicesNowAvailable` — Count of pending services that became available today
- `ServicesDelisted` — Count of services removed from global catalog

**Recommended Alarms**:
- Pending services > 30 days → Alert ops team
- Regional check errors > 0 → Alert immediately
- Email failures > 2 → Alert DevOps

---

## Documentation Links

For more details, see:

- **Developers**: [DEVELOPMENT.md](./DEVELOPMENT.md#regional-availability-monitoring) — Testing, customization, functions
- **Operations**: [REGIONAL_AVAILABILITY_OPERATIONS.md](./runbooks/REGIONAL_AVAILABILITY_OPERATIONS.md) — Tasks, troubleshooting, scripts
- **Architecture**: [ARCHITECTURE.md](./ARCHITECTURE.md#regional-availability-detection-architecture) — Design, data flow, state machine
- **Deployment**: [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) — Initial setup

---

## Key Takeaways

1. **Cautious-by-Default**: All new services blocked immediately in SCP
2. **Intelligence Only**: Regional checks inform, don't control SCP
3. **Daily Monitoring**: Pending services checked automatically each run
4. **Two Emails**: Detection (immediate) + now available (later)
5. **Early Planning**: Know what's coming before it hits your region
6. **Zero Cost Impact**: ~$1/month, minimal Lambda overhead

---

**Questions?** Check the relevant documentation above or see [README.md](./README.md) for more info.
