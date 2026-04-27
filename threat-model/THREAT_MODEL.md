# AWS Service Monitor - Threat Model

## Executive Summary

This document describes the threat model for the AWS Service Monitor solution. It identifies potential threats, evaluates their severity, and recommends mitigations.

**Overall Risk Rating**: 🟡 **MEDIUM** (Acceptable with mitigations)

| Metric | Count |
|--------|-------|
| Total Threats | 14 |
| Critical | 2 |
| High | 6 |
| Medium | 5 |
| Low | 1 |
| Mitigated | 9 |
| Accepted | 5 |

---

## System Architecture

### Key Components

1. **Lambda Function** - Service monitoring logic
2. **DynamoDB Table** - Service registry and baseline storage
3. **EventBridge Rule** - Daily execution schedule
4. **SCP Policy** - Service Control Policy target
5. **AWS Service Reference** - External service data source
6. **Amazon SES** - Email notifications
7. **CloudWatch Logs** - Execution logging
8. **CloudTrail** - API audit trail

### Trust Boundaries

```
┌─────────────────────────────────────────────────┐
│          AWS Management Account                 │
│  ┌────────────┐      ┌──────────────┐          │
│  │  Lambda    │─────▶│  DynamoDB    │          │
│  └────────────┘      └──────────────┘          │
│       │                                         │
│       ├─────────────────────▶ SCP Policy       │
│       │                                         │
│       ├─────────────────────▶ CloudWatch Logs  │
│       │                                         │
│       └──────────────────────────────┐         │
│                                      │         │
│  ┌────────────┐                     │         │
│  │ EventBridge│─────────────────────┘         │
│  └────────────┘                               │
└─────────────────────────────────────────────────┘
         │                    │
         │                    ▼
    HTTPS│            ┌──────────────┐
         │            │ CloudTrail   │
         ▼            └──────────────┘
┌─────────────────────────────────────────────────┐
│        External Services                        │
│  ┌──────────────────┐    ┌────────────┐       │
│  │ Service Reference│    │  SES Email │       │
│  └──────────────────┘    └────────────┘       │
└─────────────────────────────────────────────────┘
```

---

## Threat Catalog

### T001: Man-in-the-Middle Attack on Service Reference

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟢 LOW | **Risk**: LOW

**Description**: Attacker intercepts HTTPS connection to AWS Service Reference and injects malicious service list.

**Impact**: 
- Corrupted service list received
- False services added to SCP
- Potential policy conflicts

**Existing Controls**:
- ✅ TLS 1.2+ enforcement
- ✅ HTTPS certificate validation
- ✅ AWS managed service endpoint

**Residual Risk**: Very Low

**Recommendation**: ✅ **ACCEPT**

**Rationale**: HTTPS with certificate validation and AWS managed endpoint make this very unlikely. The additional security benefit of pinning would be minimal.

---

### T002: Service Reference Unavailability

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟢 LOW | **Risk**: LOW

**Description**: AWS Service Reference endpoint becomes unavailable, preventing service fetch.

**Impact**:
- Missing monitoring cycle
- Delayed service detection
- No error notification

**Existing Controls**:
- ✅ Error handling in Lambda
- ✅ 30-second timeout
- ✅ CloudWatch logging

**Residual Risk**: Low

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```python
# Add retry logic with exponential backoff
max_retries = 3
backoff = [1, 2, 4]  # seconds

for attempt in range(max_retries):
    try:
        return requests.get(SERVICE_REFERENCE_URL, timeout=30)
    except RequestException:
        if attempt < max_retries - 1:
            time.sleep(backoff[attempt])
        else:
            raise
```

---

### T003: Unauthorized DynamoDB Access

**Severity**: 🔴 HIGH | **Likelihood**: 🟡 MEDIUM | **Risk**: MEDIUM**

**Description**: User with IAM permissions directly modifies DynamoDB table, adding/removing services.

**Impact**:
- Corrupted service registry
- Missed service detections
- False positives in SCP

**Existing Controls**:
- ✅ IAM role restrictions
- ✅ DynamoDB encryption
- ✅ CloudTrail logging

**Residual Risk**: Medium

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```hcl
# Use KMS encryption
resource "aws_kms_key" "dynamodb" {
  enable_key_rotation = true
}

resource "aws_dynamodb_table" "service_registry" {
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }
}

# Restrict DynamoDB permissions further
resource "aws_iam_role_policy" "lambda_dynamodb" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query"  # Not Scan or DeleteItem
      ]
      Resource = aws_dynamodb_table.service_registry.arn
      Condition = {
        IpAddress = {
          "aws:SourceIp" = ["10.0.0.0/8"]  # VPC only
        }
      }
    }]
  })
}
```

---

### T004: DynamoDB Data Tampering

**Severity**: 🔴 HIGH | **Likelihood**: 🟢 LOW | **Risk**: MEDIUM**

**Description**: Attacker deletes baseline marker, triggering reinitialization and hiding new services.

**Impact**:
- Loss of detection capability
- New services undetected
- SCP bypass potential

**Existing Controls**:
- ✅ Conditional writes (prevents race condition)
- ✅ CloudTrail logging
- ✅ DynamoDB PITR (35-day recovery)

**Residual Risk**: Low

**Recommendation**: ✅ **ACCEPT** (with optional enhancements)

**Optional Mitigations**:
```python
# Add checksum verification
def verify_baseline_integrity():
    """Verify baseline hasn't been tampered with."""
    baseline = get_baseline()
    
    # Calculate expected checksum
    service_data = json.dumps(sorted(list(baseline['services'])))
    expected_checksum = hashlib.sha256(service_data.encode()).hexdigest()
    
    # Compare with stored
    if baseline['checksum'] != expected_checksum:
        logger.error("Baseline integrity check FAILED - possible tampering")
        send_security_alert("Baseline tampered with")
        raise SecurityException("Baseline integrity violation")
    
    logger.info("Baseline integrity verified")
```

---

### T005: Unauthorized SCP Policy Modification

**Severity**: 🔴 CRITICAL | **Likelihood**: 🟡 MEDIUM | **Risk**: HIGH**

**Description**: Attacker modifies SCP policy directly, bypassing monitoring and approval workflow.

**Impact**:
- SCP policy controls bypassed
- Compliance violation
- Security controls circumvented
- Unauthorized services accessible

**Existing Controls**:
- ✅ IAM permissions restricted
- ✅ CloudTrail logging
- ✅ Approval workflow

**Residual Risk**: Medium

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```hcl
# Restrict organizations:UpdatePolicy permission
resource "aws_iam_role_policy" "lambda_scp" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = "organizations:UpdatePolicy"
      Resource = "arn:aws:organizations::*:policy/o-*/service_control_policy/p-*"
      Condition = {
        StringEquals = {
          "organizations:PolicyName" = "blacklist"  # Only this policy
        }
      }
    }]
  })
}

# Require MFA for policy changes
resource "aws_organizations_policy" "require_mfa" {
  # Policy requiring MFA for organizations:UpdatePolicy
}
```

**Additional Detection**:
```hcl
# CloudWatch alarm for unauthorized SCP changes
resource "aws_cloudwatch_event_rule" "scp_changes" {
  event_pattern = jsonencode({
    source      = ["aws.organizations"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["UpdatePolicy"]
      requestParameters = {
        policyId = ["p-xxxxx"]
      }
    }
  })
}
```

---

### T006: Broken SCP Policy Deployment

**Severity**: 🔴 HIGH | **Likelihood**: 🟢 VERY LOW | **Risk**: LOW**

**Description**: Invalid SCP policy JSON is deployed, breaking organization policies.

**Impact**:
- SCP policies fail to enforce
- Compliance gaps
- Service restrictions broken

**Existing Controls**:
- ✅ Policy syntax validation (before update)
- ✅ Approval workflow

**Residual Risk**: Very Low

**Recommendation**: ✅ **ACCEPT**

**Rationale**: Syntax validation prevents this. The JSON is validated before any API call:

```python
def validate_policy_document(policy: Dict) -> Tuple[bool, str]:
    """Validate IAM policy syntax."""
    # Check structure
    if 'Statement' not in policy:
        return False, "Missing Statement"
    
    # Check each statement
    for stmt in policy['Statement']:
        if stmt.get('Effect') not in ['Allow', 'Deny']:
            return False, f"Invalid Effect: {stmt.get('Effect')}"
        if 'Action' not in stmt or 'Resource' not in stmt:
            return False, "Missing required fields"
    
    # Test JSON serialization
    json.dumps(policy)
    return True, "Valid"
```

---

### T007: SCP Policy Bypass

**Severity**: 🔴 CRITICAL | **Likelihood**: 🟢 LOW | **Risk**: HIGH**

**Description**: Attacker finds way to bypass SCP deny policies through organization structure manipulation.

**Impact**:
- SCP policies ineffective
- Compliance violation
- Unauthorized service usage

**Existing Controls**:
- ✅ SCP policy structure
- ✅ IAM policies

**Residual Risk**: Medium

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```python
# Monitor organization structure changes
def monitor_org_changes():
    """Alert on org structure changes."""
    org = boto3.client('organizations')
    
    # Check for new OUs
    ous = org.list_organizational_units_for_parent(
        ParentId=root_id
    )
    
    # Track against baseline
    new_ous = set(ou['Id'] for ou in ous['OrganizationalUnits']) - baseline_ous
    
    if new_ous:
        logger.warning(f"New OUs detected: {new_ous}")
        send_security_alert(f"Organization structure changed: {new_ous}")
```

**Restrict in SCP**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Action": [
        "organizations:CreateOrganizationalUnit",
        "organizations:MoveAccount"
      ],
      "Resource": "*"
    }
  ]
}
```

---

### T008: Denial of Service on DynamoDB

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟢 LOW | **Risk**: LOW**

**Description**: Attacker causes high API call volume to DynamoDB, degrading performance.

**Impact**:
- Service performance degradation
- Potential cost increase
- Monitoring delays

**Existing Controls**:
- ✅ DynamoDB on-demand pricing (auto-scales)
- ✅ CloudWatch monitoring
- ✅ Lambda timeout (300s)

**Residual Risk**: Low

**Recommendation**: ✅ **ACCEPT**

**Rationale**: DynamoDB on-demand automatically scales. Cost would increase, but functionality is preserved.

**Optional: Add Alert**:
```hcl
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name  = "service-monitor-throttle"
  metric_name = "UserErrors"
  namespace   = "AWS/DynamoDB"
  threshold   = "1"
  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

---

### T009: Email Injection Attack

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟢 LOW | **Risk**: LOW**

**Description**: Service names contain email injection payloads, modifying email content.

**Impact**:
- Email content modified
- Phishing emails sent
- User confusion/exploitation

**Existing Controls**:
- ✅ Service name format validation
- ✅ HTML escaping in email generation

**Residual Risk**: Very Low

**Recommendation**: ✅ **ACCEPT**

**Code Evidence**:
```python
def generate_html_email(services):
    """Email with proper HTML escaping."""
    from html import escape
    
    # Services are escaped
    services_html = '\n'.join([
        f'<li>{escape(service)}</li>'
        for service in sorted(services)
    ])
    
    # Service names cannot contain CRLF or SMTP commands
    return html_template.format(services=services_html)

def validate_service_names(services):
    """Validate service names."""
    pattern = re.compile(r'^[a-z0-9\-]+$')
    for service in services:
        if not pattern.match(service):
            raise ValueError(f"Invalid service: {service}")
```

---

### T010: Information Disclosure via Email

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟡 MEDIUM | **Risk**: MEDIUM**

**Description**: Service names in email reveal organization's service usage patterns.

**Impact**:
- Architecture visible to email recipients
- Sensitive information disclosed
- Competitive intelligence leakage

**Existing Controls**:
- ✅ Email recipient verification (SES)
- ✅ Approval of recipients in code

**Residual Risk**: Medium

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```terraform
# Use distribution lists instead of individual addresses
variable "email_recipients" {
  default = [
    "security-team@company.com"  # DL, not individuals
  ]
}

# Audit email forwarding
resource "aws_cloudwatch_event_rule" "suspicious_forwarding" {
  event_pattern = jsonencode({
    source      = ["aws.ses"]
    detail-type = ["SES Send"]
    detail = {
      destination = {
        toAddresses = [{
          exists = true
        }]
      }
    }
  })
}
```

---

### T011: Unauthorized Lambda Invocation

**Severity**: 🔴 HIGH | **Likelihood**: 🟢 LOW | **Risk**: MEDIUM**

**Description**: Attacker invokes Lambda function outside scheduled time.

**Impact**:
- Unscheduled policy updates
- Unexpected service blacklisting
- Service disruption

**Existing Controls**:
- ✅ Lambda resource policy
- ✅ IAM role restrictions
- ✅ CloudTrail logging

**Residual Risk**: Low

**Recommendation**: ✅ **ACCEPT**

**Evidence**:
```hcl
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.service_monitor.function_name
  principal     = "events.amazonaws.com"  # Only EventBridge
  source_arn    = aws_cloudwatch_event_rule.daily_monitor.arn
}

# Only EventBridge can invoke (no direct invocation allowed)
```

---

### T012: EventBridge Schedule Manipulation

**Severity**: 🔴 HIGH | **Likelihood**: 🟢 LOW | **Risk**: MEDIUM**

**Description**: Attacker modifies EventBridge schedule to disable or accelerate monitoring.

**Impact**:
- Monitoring disabled or excessive
- Service detection missed
- Unintended policy updates

**Existing Controls**:
- ✅ IAM permissions
- ✅ CloudTrail logging

**Residual Risk**: Low

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```hcl
# Restrict EventBridge permissions
resource "aws_iam_role_policy" "restrict_eventbridge" {
  policy = jsonencode({
    Statement = [{
      Effect = "Deny"
      Action = [
        "events:PutRule",
        "events:DeleteRule",
        "events:DisableRule"
      ]
      Resource = "arn:aws:events:*:*:rule/service-monitor-*"
    }]
  })
}

# Alert on modifications
resource "aws_cloudwatch_event_rule" "eventbridge_changes" {
  event_pattern = jsonencode({
    source      = ["aws.events"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["PutRule", "DeleteRule", "DisableRule"]
    }
  })
}
```

---

### T013: CloudWatch Log Tampering

**Severity**: 🔴 HIGH | **Likelihood**: 🟢 LOW | **Risk**: MEDIUM**

**Description**: Attacker deletes CloudWatch logs to hide evidence of activities.

**Impact**:
- Audit trail lost
- Evidence of tampering hidden
- Compliance violation

**Existing Controls**:
- ✅ IAM permissions
- ✅ CloudTrail logging
- ✅ Log retention policy

**Residual Risk**: Low

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```hcl
# Export logs to S3 for immutable storage
resource "aws_kinesis_firehose_delivery_stream" "logs_to_s3" {
  name        = "service-monitor-logs"
  destination = "extended_s3"
  
  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.logs.arn
    
    # Enable S3 Object Lock for immutability
    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.logs.name
    }
  }
}

# Restrict log deletion
resource "aws_iam_role_policy" "restrict_log_deletion" {
  policy = jsonencode({
    Statement = [{
      Effect = "Deny"
      Action = [
        "logs:DeleteLogGroup",
        "logs:DeleteLogStream"
      ]
      Resource = "*"
    }]
  })
}
```

---

### T014: Sensitive Information in CloudWatch Logs

**Severity**: 🟡 MEDIUM | **Likelihood**: 🟡 MEDIUM | **Risk**: MEDIUM**

**Description**: CloudWatch logs contain service names and configuration details.

**Impact**:
- Architecture visibility
- Configuration details exposed
- Service usage patterns revealed

**Existing Controls**:
- ✅ IAM access control
- ✅ Encryption at rest
- ✅ CloudTrail logging of log access

**Residual Risk**: Medium

**Recommendation**: 🟡 **MITIGATE**

**Suggested Mitigations**:
```python
# Reduce log verbosity
logger.info(f"Processing new services")  # Generic
# Instead of:
# logger.info(f"Processing: {new_services}")  # Specific names exposed

# Implement log masking
import re

def mask_logs(log_message):
    """Mask sensitive data in logs."""
    # Mask service names
    log_message = re.sub(r'\b[a-z0-9\-]+\b', '***', log_message)
    # Mask email addresses
    log_message = re.sub(r'\S+@\S+', '***@***.***', log_message)
    return log_message
```

**Restrict Access**:
```hcl
resource "aws_iam_role_policy" "restrict_logs" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = "logs:GetLogEvents"
      Resource = aws_cloudwatch_log_group.lambda_logs.arn
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/SecurityAudit"
      }
    }]
  })
}
```

---

## Risk Summary

### Risk Matrix

```
                 Likelihood
              Low  Medium  High
Severity:
Critical      [T004][T005][T007]
              [T004][T005][T007]
              
High          [T003][T006][T011]
              [T012][T013]
              
Medium        [T001][T002][T008]
              [T010][T014]
              
Low           [T009]
```

### Threat Status

| Status | Count | Threats |
|--------|-------|---------|
| ✅ Accept | 5 | T001, T006, T009, T011, T008 |
| 🟡 Mitigate | 9 | T002, T003, T004, T005, T007, T010, T012, T013, T014 |

---

## Implementation Roadmap

### Phase 1: Critical (Week 1)

```
Priority 1: Policy Drift Detection
├─ Detect unauthorized SCP changes
├─ Send alerts via SNS
└─ Estimated effort: 4 hours

Priority 2: KMS Encryption
├─ Enable customer-managed keys for DynamoDB
├─ Update Lambda IAM policy
└─ Estimated effort: 2 hours

Priority 3: MFA Requirement
├─ Require MFA for organization changes
├─ Terraform configuration
└─ Estimated effort: 2 hours
```

### Phase 2: Important (Month 1)

```
Priority 1: Baseline Integrity Verification
├─ Add checksum calculation/verification
├─ Alert on tampering
└─ Estimated effort: 3 hours

Priority 2: Log Export to S3
├─ Set up Kinesis Firehose
├─ S3 Object Lock for immutability
└─ Estimated effort: 3 hours

Priority 3: EventBridge Monitoring
├─ Alert on rule modifications
├─ CloudWatch alarm
└─ Estimated effort: 2 hours
```

### Phase 3: Nice-to-Have (Quarter 2)

```
Priority 1: Service Name Encryption
├─ Encrypt in logs and emails
├─ Tokenization approach
└─ Estimated effort: 8 hours

Priority 2: Multi-Region Setup
├─ Failover capability
├─ Data replication
└─ Estimated effort: 20 hours

Priority 3: Advanced Monitoring
├─ Service usage analytics
├─ Anomaly detection
└─ Estimated effort: 10 hours
```

---

## Conclusion

The AWS Service Monitor has **acceptable risk** with proper implementation of recommended mitigations. The solution demonstrates good security practices with strong IAM controls, encryption, and logging.

**Current Risk Level**: 🟡 **MEDIUM** (Acceptable)

**With Phase 1 Implementation**: 🟢 **LOW** (Good)

**With Phases 1-2 Implementation**: 🟢 **VERY LOW** (Excellent)

---

## Appendix: STRIDE Mapping

| Threat | Category | Affected Component |
|--------|----------|-------------------|
| T001 | Spoofing | Service Reference |
| T002 | Tampering | Service Reference |
| T003 | Tampering | DynamoDB |
| T004 | Tampering | DynamoDB |
| T005 | Tampering | SCP Policy |
| T006 | Tampering | SCP Policy |
| T007 | Elevation | SCP Policy |
| T008 | DoS | DynamoDB |
| T009 | Injection | Email |
| T010 | Information Disclosure | Email/Logs |
| T011 | Elevation | Lambda |
| T012 | Tampering | EventBridge |
| T013 | Tampering | CloudWatch |
| T014 | Information Disclosure | CloudWatch |
