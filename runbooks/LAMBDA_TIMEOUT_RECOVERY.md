# Runbook: Lambda Timeout Recovery

**Severity**: WARNING/CRITICAL  
**Response Time**: < 30 minutes  
**Runbook Owner**: DevOps/Platform Team

---

## Symptom Detection

**Alert triggers**:
- `service-monitor-lambda-duration-high` (> 270 seconds = 90% of 300s timeout)
- `service-monitor-lambda-timeout` (execution hits 300s limit)

**Log indicators**:
```
Task timed out after 300.00 seconds
Duration exceeded alarm threshold
```

---

## Diagnosis (5 min)

### Step 1: Check CloudWatch Metrics

```bash
# Check recent duration metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=aws-service-monitor \
  --start-time $(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average,Maximum \
  --region eu-west-2
```

**Key questions**:
- Is duration consistently high (150s+)?
- Is it gradually increasing?
- Did it spike suddenly?

### Step 2: Analyze CloudWatch Logs

```bash
# Get execution durations
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "[duration]" \
  --region eu-west-2 \
  --start-time $(date -d '24 hours ago' +%s)000 \
  --query 'events[].message' | jq -r '.[] | select(. | contains("execution"))'
```

**Look for**:
- Service fetch time increasing
- DynamoDB operations slow
- SCP policy updates slow

### Step 3: Check External Factors

```bash
# Verify AWS Service Health
# https://status.aws.amazon.com

# Check if service reference endpoint is responding
curl -w "Status: %{http_code}\nTime: %{time_total}s\n" \
  https://servicereference.eu-west-2.amazonaws.com/ -o /dev/null -s

# Should respond < 5 seconds
```

---

## Root Cause Analysis

### Cause 1: Service List Growing
**Symptoms**:
- Execution time increases proportionally to service count
- Scanning and SCP update slower

**Verification**:
```bash
# Check service count trend
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --select COUNT \
  --filter-expression "NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  | jq '.Count'

# Compare to previous week - should be < 5% growth
```

**Solution**: See "Mitigation" section

### Cause 2: DynamoDB Throttling
**Symptoms**:
- On-demand DynamoDB with sudden spikes in consumed capacity
- SCP policy very large (causing large UpdateItem)

**Verification**:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedWriteCapacityUnits \
  --dimensions Name=TableName,Value=aws-service-monitor-registry \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum
```

**Solution**: On-demand automatically scales; may need Lambda memory increase

### Cause 3: Service Reference Endpoint Slow
**Symptoms**:
- Service fetch command is slow
- Other operations complete quickly

**Verification**:
```bash
# Time service fetch
time curl -s https://servicereference.eu-west-2.amazonaws.com/ | jq '.' > /dev/null
```

**Solution**: This is AWS-side; increase Lambda timeout as temporary fix

### Cause 4: SCP Policy Large/Slow
**Symptoms**:
- Many services in SCP blacklist
- UpdatePolicy API call slow

**Verification**:
```bash
aws organizations describe-policy \
  --policy-id p-xxxxx \
  --content | jq '.Content | length'

# Should be < 10KB; > 20KB is concerning
```

**Solution**: See "Mitigation" section

---

## Mitigation (15 min)

### Option A: Increase Lambda Memory (QUICK FIX)
**Time**: 5 minutes  
**Temporary until root cause fixed**

```bash
# Current: 512MB
# Update to: 1024MB

terraform apply -var="lambda_memory=1024"
# OR manually via console:
# Lambda > aws-service-monitor > Configuration > General > Memory: 1024
```

**Cost impact**: +$0.10/month per execution  
**Benefit**: Proportional CPU increase (faster execution)

### Option B: Increase Lambda Timeout (TEMPORARY)
**Time**: 5 minutes  
**Only as temporary safety net**

```bash
# Current: 300 seconds
# Update to: 600 seconds

terraform apply -var="lambda_timeout=600"
# OR manually via console:
# Lambda > Configuration > General > Timeout: 600
```

**WARNING**: Masks underlying performance issue  
**Use only**: Until root cause is addressed

### Option C: Optimize Service List Comparison
**Time**: 30 minutes  
**Permanent fix for growth**

If service count has grown significantly:

```python
# In lambda/index.py, optimize the service comparison
# Current: Full service set comparison
# Improved: Incremental tracking

# Consider:
# 1. Cache service list in DynamoDB TTL
# 2. Use pagination for SCP updates
# 3. Split service blacklist into multiple SCPs
```

### Option D: Optimize SCP Update Size
**Time**: 2 hours  
**If SCP policy is > 20KB**

```python
# Split monolithic SCP into multiple policies
# Example:
# - blacklist-services-a-m.json
# - blacklist-services-n-z.json

# Or use service grouping:
# - blacklist-compute.json
# - blacklist-database.json
# - blacklist-storage.json
```

---

## Resolution Steps (Choose One)

### Resolution 1: Increase Memory + Monitor (IMMEDIATE)

```bash
# 1. Update Lambda memory
aws lambda update-function-configuration \
  --function-name aws-service-monitor \
  --memory-size 1024 \
  --region eu-west-2

# 2. Wait for update to complete
sleep 5

# 3. Manually trigger Lambda
aws lambda invoke \
  --function-name aws-service-monitor \
  --payload '{}' \
  --region eu-west-2 \
  response.json

# 4. Check duration in logs
aws logs tail /aws/lambda/aws-service-monitor \
  --follow --format short --filter-pattern "milliseconds"

# Should see improvement immediately
```

### Resolution 2: Monitor for 24 Hours
```bash
# 1. Keep increased memory
# 2. Monitor duration daily
# 3. Verify next execution completes
# 4. If still > 270s, implement permanent fix below
```

### Resolution 3: Permanent Optimization

**If service count grew**:
```bash
# Archive and cleanup old entries
# Add TTL to service entries (5-year expiry)
# Implement baseline version tracking
```

**If SCP too large**:
```bash
# Implement multiple SCP policies
# Rotate services across policies
# Document SCP strategy in README
```

---

## Verification (5 min)

```bash
# 1. Check alarm cleared
aws cloudwatch describe-alarms \
  --alarm-names service-monitor-lambda-duration-high \
  --state-value OK

# 2. Monitor next scheduled execution (24 hours later)
# 3. Verify duration stays < 270 seconds
# 4. Check dashboard for consistent performance
```

---

## Prevention

### Monitor Baseline
**Establish baseline metrics**:
```bash
# Get 2-week average
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=aws-service-monitor \
  --start-time $(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 \
  --statistics Average,Maximum > lambda_baseline.json

# Your baseline: should be 10-20 seconds
# Alert threshold: > 270 seconds (27x baseline)
```

### Capacity Planning
- Review monthly service growth trends
- Plan for 2x service count in next 12 months
- Consider graduated SCP split strategy

### Performance Tuning
- Monthly review of execution logs
- Identify slow service reference endpoint
- Optimize DynamoDB queries if needed

---

## Rollback

**If memory increase causes issues**:
```bash
# Revert to original 512MB
aws lambda update-function-configuration \
  --function-name aws-service-monitor \
  --memory-size 512 \
  --region eu-west-2
```

---

## Escalation

If timeout still occurs after 1024MB memory:
1. Contact AWS Support for service endpoint performance
2. Consider architecture change (Lambda -> EC2/ECS)
3. Split monitoring into multiple functions

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24  
**Review Date**: 2026-05-24
