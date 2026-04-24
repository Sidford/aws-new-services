# Consolidated Incident Response Guide

**Severity**: ALL LEVELS  
**Response Time**: Varies by issue  
**Runbook Owner**: On-Call Engineer

---

## Quick Diagnosis

When an alarm fires, follow this flowchart:

```
Alarm Triggered
    ↓
Severity HIGH? → YES → Go to CRITICAL section below
    ↓ NO
Severity MEDIUM? → YES → Go to WARNING section below
    ↓ NO
Severity LOW → Go to INFORMATIONAL section below
```

---

## CRITICAL ALERTS (< 15 min response)

### 1. Baseline Integrity Violation
**Alarm**: `service-monitor-baseline-integrity-violation`

**Immediate**:
- [ ] Check CloudWatch Logs for violation details
- [ ] If active tampering suspected, isolate DynamoDB access
- [ ] Follow: [BASELINE_INTEGRITY_VIOLATION.md](./BASELINE_INTEGRITY_VIOLATION.md)

**Timeline**: 0-5 min action, 30 min investigation

---

### 2. Lambda Errors
**Alarm**: `service-monitor-lambda-errors`

**Immediate**:
- [ ] Check CloudWatch Logs for specific error message
- [ ] Identify error type (timeout, DynamoDB, SCP, validation)
- [ ] Follow appropriate runbook:
  - Timeout → [LAMBDA_TIMEOUT_RECOVERY.md](./LAMBDA_TIMEOUT_RECOVERY.md)
  - DynamoDB → [DYNAMODB_RECOVERY.md](./DYNAMODB_RECOVERY.md)
  - Validation → Check service names in [LAMBDA_TIMEOUT_RECOVERY.md](./LAMBDA_TIMEOUT_RECOVERY.md)

**Timeline**: 0-2 min diagnosis, 5-30 min resolution

---

### 3. Lambda Timeout
**Alarm**: `service-monitor-lambda-timeout`

**Immediate**:
- [ ] Function exceeded 300 second limit
- [ ] Follow: [LAMBDA_TIMEOUT_RECOVERY.md](./LAMBDA_TIMEOUT_RECOVERY.md) Option A (increase memory)
- [ ] Timeline: 5 minutes to resolve

---

### 4. EventBridge Rule Disabled
**Alarm**: `service-monitor-eventbridge-rule-disabled`

**Immediate**:
```bash
# Check rule status
aws events describe-rule \
  --name aws-service-monitor-daily \
  --region us-east-1

# Expected: State = ENABLED
# If disabled:
aws events enable-rule \
  --name aws-service-monitor-daily \
  --region us-east-1
```

**Timeline**: 2-5 minutes

---

## WARNING ALERTS (< 1 hour response)

### 1. Lambda Duration High
**Alarm**: `service-monitor-lambda-duration-high`

**Diagnosis**:
- Duration > 270 seconds (approaching timeout)
- Follow: [LAMBDA_TIMEOUT_RECOVERY.md](./LAMBDA_TIMEOUT_RECOVERY.md)

**Actions**:
- [ ] Increase Lambda memory to 1024MB
- [ ] Monitor next execution
- [ ] Implement permanent fix if needed

**Timeline**: 5 min quick fix, 2 hour permanent solution

---

### 2. DynamoDB Read Throttles
**Alarm**: `service-monitor-dynamodb-read-throttles`

**Actions**:
```bash
# Check consumed capacity
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedReadCapacityUnits \
  --dimensions Name=TableName,Value=aws-service-monitor-registry \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

**Timeline**: Monitor, should auto-recover (on-demand mode)

---

### 3. DynamoDB Write Throttles
**Alarm**: `service-monitor-dynamodb-write-throttles`

**Same as read throttles** - typically resolves automatically

---

### 4. Missed Execution
**Alarm**: `service-monitor-missed-execution`

**Diagnosis**:
```bash
# Check Lambda invocation logs
aws logs tail /aws/lambda/aws-service-monitor \
  --since 24h

# Check EventBridge rule
aws events describe-rule \
  --name aws-service-monitor-daily

# Check rule targets
aws events list-targets-by-rule \
  --rule aws-service-monitor-daily
```

**Likely Causes**:
1. EventBridge rule disabled → Enable it
2. Lambda permission removed → Re-apply via Terraform
3. Lambda doesn't exist → Redeploy via Terraform

**Timeline**: 5-15 minutes

---

## INFORMATIONAL (< 8 hour response)

**Severity**: LOW priority  
**Response**: Next business day if not urgent

---

## Investigation Template

Use this for any incident:

```
Incident Report Template
========================

1. DETECTION
   - Time detected: [UTC timestamp]
   - How detected: [Alarm name / Manual discovery]
   - Severity: [CRITICAL / WARNING / INFORMATIONAL]

2. INITIAL ASSESSMENT
   - Affected component: [Lambda / DynamoDB / SCP / etc]
   - Impact: [Services blocked? Detection broken? Data loss?]
   - Estimated users affected: [#]

3. ROOT CAUSE
   - Identified cause: [Brief description]
   - Contributing factors: [List]
   - CloudTrail evidence: [Event ID / Principal / Time]

4. RESOLUTION
   - Actions taken: [Step-by-step]
   - Runbook followed: [URL]
   - Timeline: [Started at X, resolved at Y]
   - Verification: [How confirmed fixed]

5. PREVENTION
   - Root cause prevention: [What changed to prevent recurrence]
   - Monitoring improvement: [What alerts added]
   - Process improvement: [What changed procedurally]

6. FOLLOW-UP
   - Change control: [PR/ticket ID if infrastructure changed]
   - Post-mortem date: [Schedule date]
   - Owner: [Who is responsible for prevention]
```

---

## Escalation Decision Tree

```
Can you resolve within 15 minutes?
    ├─ YES → Proceed with fix
    └─ NO  →  Is it affecting customers?
               ├─ YES → Escalate to Level 2 immediately
               └─ NO  → Continue diagnosis for 30 min max
                         ├─ Found cause? → Proceed with fix
                         └─ Not found?  → Escalate to Level 2
```

---

## Escalation Levels

### Level 1: On-Call Engineer
- Initial response and diagnosis
- Authority: Execute runbooks, temporary fixes
- Escalate if: Unresolved after 30 minutes

### Level 2: Team Lead
- Called if: Level 1 cannot resolve, customer impact
- Authority: Major changes, architecture decisions
- Escalate if: Systemic issues or repeated incidents

### Level 3: Architecture Review
- Called if: Level 2 identifies design flaw
- Authority: Design changes, long-term solutions
- Action: Schedule architecture review meeting

---

## Communication During Incident

### Status Update Template

```
[TIME] Status Update

Current Status: [IN PROGRESS / INVESTIGATING / RESOLVED]
Impact: [Description of what users can/cannot do]
Root Cause: [If identified]
ETA to Resolution: [If known]
Actions Underway: [List of current activities]

Next Update: [TIME + 15 min]
```

### Stakeholder Notification

**Notify when**:
- [ ] Services become unavailable (immediately)
- [ ] Incident will last > 15 minutes (immediately)
- [ ] Root cause identified (within 5 minutes)
- [ ] Resolution complete (within 5 minutes)

---

## Post-Incident

### Within 24 Hours
- [ ] Complete incident report
- [ ] Create follow-up tickets for prevention
- [ ] Update runbooks if needed

### Within 1 Week
- [ ] Schedule post-mortem with team
- [ ] Review CloudTrail logs for learning
- [ ] Implement quick wins for prevention

### Within 1 Month
- [ ] Implement permanent solutions
- [ ] Deploy prevention controls
- [ ] Update monitoring/dashboards

---

## Common Commands

```bash
# Check overall system status
aws cloudwatch describe-alarms --state-value ALARM

# Check recent Lambda executions
aws logs tail /aws/lambda/aws-service-monitor --since 6h

# Check DynamoDB table status
aws dynamodb describe-table --table-name aws-service-monitor-registry \
  | jq '{Status: .Table.TableStatus, Items: .Table.ItemCount}'

# Check SCP policy
aws organizations describe-policy --policy-id p-xxxxx --content

# Verify baseline
aws dynamodb get-item --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"__baseline_initialized__"}}' \
  | jq '.Item'
```

---

## Runbook Quick Reference

| Issue | Runbook | Time |
|-------|---------|------|
| Tampering detected | [Baseline Integrity](./BASELINE_INTEGRITY_VIOLATION.md) | 30 min |
| Execution timeout | [Lambda Timeout](./LAMBDA_TIMEOUT_RECOVERY.md) | 5 min |
| Bad SCP update | [SCP Rollback](./SCP_POLICY_ROLLBACK.md) | 15 min |
| DynamoDB corrupt | [DynamoDB Recovery](./DYNAMODB_RECOVERY.md) | 2 hours |
| Reset baseline | [Baseline Reset](./BASELINE_RESET.md) | 30 min |
| Cleanup services | [Registry Cleanup](./SERVICE_REGISTRY_CLEANUP.md) | 2 hours |

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-24  
**Review Date**: 2026-05-24
