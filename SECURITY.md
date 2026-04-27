# Security Considerations & Review

This document outlines security risks, mitigations, and best practices for the AWS Service Monitor solution.

## Executive Summary

**Risk Level**: 🟡 **MEDIUM** (with recommendations)

The solution uses AWS-managed services with proper IAM controls, but automated SCP modifications and external service monitoring require careful operational governance. No hardcoded credentials or data exposure risks, but approval workflows and validation should be added for production use.

---

## 1. Identity & Access Control (IAM)

### ✅ Strengths
- **No Hardcoded Credentials**: Uses IAM roles (assumed by Lambda)
- **Least Privilege Principle**: Each policy grants only required permissions
- **Separate Roles**: Lambda has dedicated execution role (not shared)
- **Trust Policy**: Lambda service can only assume the role
- **Resource-Specific Access**: DynamoDB table ARN is specified exactly

### ⚠️ Risks & Mitigations

#### Risk 1: Organizations API Permissions Too Broad
**Issue**: Current policy uses wildcard resources for Organizations API
```json
{
  "Effect": "Allow",
  "Action": [
    "organizations:ListPolicies",
    "organizations:DescribePolicy",
    "organizations:UpdatePolicy"
  ],
  "Resource": "*"
}
```

**Why**: Organizations APIs don't support resource-level permissions (ARN specification).

**Mitigation**:
- ✅ This is AWS limitation, not a code issue
- Add condition to restrict to specific policy name:
```json
{
  "Effect": "Allow",
  "Action": "organizations:*",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "organizations:PolicyName": "blacklist"
    }
  }
}
```
- Monitor CloudTrail for unexpected policy modifications

#### Risk 2: SES Permissions
**Issue**: `"ses:SendEmail"` and `"ses:SendRawEmail"` without resource restriction.

**Why**: SES doesn't support resource-level permissions by default.

**Mitigation**:
- ✅ Acceptable given SES limitations
- Verify sender email is only the monitor account
- Consider using identity policies instead:
```json
{
  "Effect": "Allow",
  "Action": "ses:SendEmail",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "ses:FromAddress": ["aws-monitor@example.com"]
    }
  }
}
```

#### Risk 3: CloudWatch Logs Access
**Issue**: Logs policy allows all log groups: `"logs:*:*:*"`

**Mitigation**:
- ✅ Already scoped to function-specific log group in Terraform
- Restrict to specific log group ARN:
```json
{
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents"
  ],
<<<<<<< HEAD
  "Resource": "arn:aws:logs:eu-west-2:ACCOUNT:log-group:/aws/lambda/aws-service-monitor:*"
}
```

**Recommended Fix**: Update `main.tf`:
```hcl
resource "aws_iam_role_policy" "lambda_logs_policy" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
    }]
  })
}
```

---

## 2. Data Protection

### ✅ Strengths
- **DynamoDB Encryption**: AWS-managed keys by default
- **TLS in Transit**: All AWS API calls use TLS 1.2+
- **No Sensitive Data**: Service registry stores only service names
- **CloudWatch Encryption**: Encrypted at rest

### ⚠️ Risks & Mitigations

#### Risk 1: CloudWatch Logs Retention
**Issue**: 14-day retention could be too long/short depending on requirements.

**Mitigation**:
```hcl
resource "aws_cloudwatch_log_group" "lambda_logs" {
  retention_in_days = 30  # Adjust based on compliance needs
}
```

#### Risk 2: DynamoDB Backup
**Issue**: No automatic backups enabled by default.

**Mitigation**:
```hcl
resource "aws_dynamodb_table" "service_registry" {
  point_in_time_recovery_specification {
    enabled = true
  }
}
```

#### Risk 3: Service Reference Fetch - HTTPS Validation
**Issue**: Code fetches from external URL without certificate validation.

**Current Code**:
```python
http = urllib3.PoolManager()
response = http.request('GET', SERVICE_REFERENCE_URL, timeout=30)
```

**Risk**: Vulnerable to Man-in-the-Middle (MITM) attacks on the fetch.

**Mitigation**:
```python
import urllib3
from urllib3.util.ssl_ import create_urllib3_context

# Enable certificate verification
http = urllib3.PoolManager(
    cert_reqs='CERT_REQUIRED',
    ca_certs=certifi.where()  # pip install certifi
)

# Or use requests library (easier, more secure by default)
import requests
response = requests.get(SERVICE_REFERENCE_URL, timeout=30, verify=True)
```

**Recommendation**: Use `requests` library instead of `urllib3`:
```bash
# Update lambda/requirements.txt
boto3>=1.26.0
requests>=2.28.0
```

```python
import requests

def fetch_aws_services() -> Set[str]:
    try:
        response = requests.get(
            SERVICE_REFERENCE_URL,
            timeout=30,
            verify=True  # Enforce HTTPS certificate validation
        )
        response.raise_for_status()  # Raise on 4xx/5xx
        data = response.json()
        # ... rest of logic
    except requests.exceptions.SSLError:
        logger.error("SSL certificate validation failed")
        return set()
    except requests.RequestException as e:
        logger.error(f"Failed to fetch: {e}")
        return set()
```

---

## 3. Service Control Policy Management

### ⚠️ Critical Risks

#### Risk 1: Automated Policy Modifications Without Approval
**Severity**: 🔴 **HIGH**

**Issue**: Lambda automatically updates SCP without human review/approval.

**Risk Scenario**:
- Service Reference contains incorrect data
- Lambda adds wrong/harmful service deny rules
- Policy breaks production workloads across org

**Mitigation Options**:

**Option A: Add Approval Workflow** (Recommended)
```python
# Create SNS topic for approvals
import boto3
sns = boto3.client('sns')

def update_scp_with_approval(scp_policy, new_services):
    # Preview the changes
    preview = generate_scp_preview(scp_policy, new_services)
    
    # Send for approval
    approval_message = f"""
    Pending SCP Update - {len(new_services)} new services
    
    Preview:
    {preview}
    
    Approve: https://console.aws.amazon.com/...
    Deny: https://console.aws.amazon.com/...
    """
    
    sns.publish(
        TopicArn=APPROVAL_TOPIC_ARN,
        Subject='SCP Update Approval Required',
        Message=approval_message
    )
    
    # Store pending update in DynamoDB
    store_pending_update(scp_policy, new_services)
```

**Option B: Manual Review Step** (Simpler)
```python
# Don't update SCP automatically
# Instead, send dry-run report
def lambda_handler(event, context):
    new_services = identify_new_services()
    
    if new_services:
        # Store in DynamoDB with status='pending_review'
        store_pending_services(new_services, status='pending_review')
        
        # Send email with "Click to approve" link
        send_approval_email(new_services)
        
        # Return without updating SCP
        return {'status': 'pending_approval'}
    
# Separate Lambda function (triggered manually or by approval)
def approve_scp_update(event, context):
    pending = get_pending_services()
    scp = get_scp_policy()
    update_scp_with_services(scp, pending)
    mark_as_approved(pending)
```

**Option C: Dry-Run Mode** (Non-Breaking)
```python
def lambda_handler(event, context):
    new_services = identify_new_services()
    
    if new_services:
        # Show what WOULD be changed
        preview_scp = generate_scp_preview(scp, new_services)
        
        # Email admin with changes for review
        send_preview_email(new_services, preview_scp)
        
        # Store for manual approval
        # Don't call update_scp()
        
        return {
            'new_services': new_services,
            'action': 'preview_sent',
            'scp_would_change': preview_scp
        }
```

#### Risk 2: Service Reference Data Integrity
**Severity**: 🟡 **MEDIUM**

**Issue**: Trusts AWS service reference without validation.

**Risk Scenario**:
- AWS service reference temporarily contains incorrect data
- Bad data propagates to SCP policy
- Takes time to discover and remediate

**Mitigation**:
```python
def validate_new_services(new_services: Set[str]) -> bool:
    """Validate services against known patterns."""
    invalid = []
    
    for service in new_services:
        # Check service name format (AWS services are lowercase alphanumeric + hyphens)
        if not re.match(r'^[a-z0-9\-]+$', service):
            invalid.append(service)
        
        # Check against known service patterns
        # AWS services are typically under 20 chars
        if len(service) > 30:
            invalid.append(service)
    
    if invalid:
        logger.warning(f"Invalid services detected: {invalid}")
        # Don't process invalid services
        new_services = new_services - set(invalid)
    
    return len(new_services) > 0

# Use in lambda_handler
if new_services:
    if not validate_new_services(new_services):
        logger.error("Validation failed, aborting update")
        return {'statusCode': 400, 'error': 'Validation failed'}
```

#### Risk 3: SCP Policy Syntax Validation
**Severity**: 🟡 **MEDIUM**

**Issue**: No validation of resulting SCP policy before update.

**Mitigation**:
```python
import json

def validate_policy_syntax(policy_document: dict) -> tuple[bool, str]:
    """Validate IAM policy syntax."""
    try:
        # Check required fields
        if 'Statement' not in policy_document:
            return False, "Missing Statement"
        
        for statement in policy_document['Statement']:
            if 'Effect' not in statement:
                return False, "Missing Effect in statement"
            if statement['Effect'] not in ['Allow', 'Deny']:
                return False, f"Invalid Effect: {statement['Effect']}"
            if 'Action' not in statement:
                return False, "Missing Action in statement"
            if 'Resource' not in statement:
                return False, "Missing Resource in statement"
        
        # Try to convert to JSON (catch serialization errors)
        json.dumps(policy_document)
        
        return True, "Valid"
    
    except Exception as e:
        return False, str(e)

def update_scp_with_services(scp_policy, new_services):
    """Update SCP with validation."""
    original_policy = copy.deepcopy(scp_policy['content'])
    
    # Make changes
    modify_policy(scp_policy['content'], new_services)
    
    # Validate syntax
    is_valid, error = validate_policy_syntax(scp_policy['content'])
    if not is_valid:
        logger.error(f"Policy validation failed: {error}")
        # Restore original
        scp_policy['content'] = original_policy
        raise ValueError(f"Invalid policy: {error}")
    
    # Update if valid
    organizations.update_policy(
        PolicyId=scp_policy['id'],
        Content=json.dumps(scp_policy['content'])
    )
```

---

## 4. Network Security

### ✅ Strengths
- **Public HTTP Not Used**: Only HTTPS for service reference
- **No Open Ports**: Lambda doesn't need inbound access
- **No VPC Required**: Reduces attack surface

### ⚠️ Risks

#### Risk 1: Lambda Internet Access
**Issue**: Lambda has outbound internet access to fetch service reference.

**Mitigation**:
- ✅ Acceptable for this use case
- Monitor outbound traffic with VPC Flow Logs (if VPC used)
- Whitelist destination IPs if possible

#### Risk 2: DNS Spoofing
**Issue**: Service reference URL could be DNS-spoofed.

**Mitigation**:
```python
import socket

def validate_service_reference_domain():
    """Verify service reference domain."""
<<<<<<< HEAD
    domain = "servicereference.eu-west-2.amazonaws.com"
=======
    domain = "servicereference.us-east-1.amazonaws.com"
>>>>>>> origin/main
    
    try:
        ip = socket.gethostbyname(domain)
        # Verify IP is AWS IP range
        if not is_aws_ip(ip):
            raise Exception(f"Service reference DNS resolved to non-AWS IP: {ip}")
    except socket.gaierror:
        raise Exception("Service reference domain resolution failed")

def is_aws_ip(ip):
    """Check if IP is in AWS IP ranges."""
    # Use boto3 to get current AWS IP ranges
    import requests
    response = requests.get('https://ip-ranges.amazonaws.com/ip-ranges.json')
    ranges = response.json()
    
    # Check if IP is in any AWS CIDR block
    for prefix in ranges['prefixes']:
        if ip_in_cidr(ip, prefix['ip_prefix']):
            return True
    return False
```

---

## 5. Email & SES Security

### ⚠️ Risks

#### Risk 1: Email Address Verification
**Issue**: If recipients not verified in SES, emails won't be delivered (if in sandbox).

**Mitigation**:
```bash
# Verify all addresses before deployment
aws ses verify-email-identity --email-address ops-team@example.com
```

#### Risk 2: Email Content Injection
**Issue**: Service names could theoretically contain email/HTML injection.

**Mitigation**:
```python
from html import escape
import email.utils

def generate_html_email(services: List[str], timestamp: str) -> str:
    """Generate HTML with proper escaping."""
    # Escape service names for HTML
    services_html = '\n'.join([
        f'                <li>{escape(service)}</li>'
        for service in sorted(services)
    ])
    
    # Validate timestamp format
    try:
        datetime.fromisoformat(timestamp)
    except ValueError:
        timestamp = datetime.utcnow().isoformat()
    
    html = f"""<html>..."""
    return html

def generate_text_email(services: List[str], timestamp: str) -> str:
    """Generate text with proper escaping."""
    # Text doesn't need HTML escaping, but validate
    services_text = '\n'.join([
        f'  - {service}'  # Plain text safe
        for service in sorted(services)
    ])
    return f"""..."""
```

#### Risk 3: Email Recipients List Exposure
**Issue**: Email recipients list stored in Lambda environment variables.

**Risk**: Could be visible in Lambda console, CloudTrail, or logs.

**Mitigation**:
```hcl
# Option 1: Use AWS Secrets Manager
resource "aws_secretsmanager_secret" "email_recipients" {
  name = "aws-service-monitor/email-recipients"
}

resource "aws_secretsmanager_secret_version" "email_recipients" {
  secret_id = aws_secretsmanager_secret.email_recipients.id
  secret_string = jsonencode({
    recipients = var.email_recipients
    sender     = var.sender_email
  })
}

# In Lambda, fetch from Secrets Manager
import boto3
secrets = boto3.client('secretsmanager')
secret = json.loads(secrets.get_secret_value(
    SecretId='aws-service-monitor/email-recipients'
)['SecretString'])
EMAIL_RECIPIENTS = secret['recipients']
```

```python
# Option 2: Use AWS Systems Manager Parameter Store
import boto3
ssm = boto3.client('ssm')

# At Lambda startup
EMAIL_RECIPIENTS = json.loads(
    ssm.get_parameter(
        Name='/aws-service-monitor/email-recipients',
        WithDecryption=True
    )['Parameter']['Value']
)
```

---

## 6. Lambda Security

### ⚠️ Risks

#### Risk 1: Timeout / Hanging
**Issue**: Lambda times out during service fetch or SCP update.

**Current**: 300 second timeout

**Risk**: Could leave policy in inconsistent state.

**Mitigation**:
```python
import signal

def timeout_handler(signum, frame):
    raise TimeoutError("Operation exceeded timeout")

def lambda_handler(event, context):
    # Set signal alarm
    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(int(context.get_remaining_time_in_millis() / 1000) - 10)
    
    try:
        # Main logic with transaction-like behavior
        transaction = {
            'services': None,
            'ddb_written': False,
            'scp_updated': False,
            'email_sent': False
        }
        
        new_services = identify_new_services()
        transaction['services'] = new_services
        
        # Only proceed if time permits
        if context.get_remaining_time_in_millis() < 30000:
            logger.warning("Insufficient time remaining, aborting")
            return {'statusCode': 408, 'error': 'timeout'}
        
        # ... continue with other operations
    
    finally:
        signal.alarm(0)  # Cancel alarm
```

#### Risk 2: Cold Start Delay
**Issue**: Lambda cold start could cause timeout.

**Mitigation**:
```hcl
resource "aws_lambda_function" "service_monitor" {
  ephemeral_storage {
    size = 512  # MB, can improve cold start
  }
  
  memory_size = 512  # Larger memory = faster CPU = faster cold start
}

# Or use Lambda Provisioned Concurrency
resource "aws_lambda_provisioned_concurrency_config" "service_monitor" {
  function_name                     = aws_lambda_function.service_monitor.function_name
  provisioned_concurrent_executions = 1
  qualifier                         = aws_lambda_function.service_monitor.version
}
```

#### Risk 3: Unhandled Exceptions
**Issue**: Exceptions could leave system in inconsistent state.

**Mitigation**:
```python
def lambda_handler(event, context):
    try:
        # ... main logic ...
        return {'statusCode': 200, 'body': 'Success'}
    
    except TimeoutError:
        logger.error("Operation timeout - possible partial update")
        # Don't update DDB with success if SCP might not be updated
        return {'statusCode': 408, 'error': 'timeout'}
    
    except Exception as e:
        logger.exception("Unexpected error")
        # Send alert email
        send_error_alert(str(e), traceback.format_exc())
        return {'statusCode': 500, 'error': str(e)}
```

---

## 7. Operational Security

### ⚠️ Risks

#### Risk 1: No Alerting on Policy Drift
**Issue**: If someone manually changes the SCP, monitoring won't detect it.

**Mitigation**:
```python
def lambda_handler(event, context):
    current_policy = get_scp_policy()
    expected_policy = load_expected_policy()  # From Terraform state
    
    if current_policy != expected_policy:
        logger.warning("SCP policy drift detected")
        send_drift_alert(current_policy, expected_policy)
        # Don't update if drift exists
        return {'statusCode': 409, 'error': 'policy_drift'}
```

#### Risk 2: No Rate Limiting
**Issue**: EventBridge could invoke Lambda excessively if misconfigured.

**Mitigation**:
```python
# Add DLQ (Dead Letter Queue) for failed invocations
resource "aws_sqs_queue" "lambda_dlq" {
  name = "aws-service-monitor-dlq"
}

resource "aws_lambda_function" "service_monitor" {
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
}
```

#### Risk 3: No Change Notifications
**Issue**: Changes to SCP aren't explicitly logged/alerted.

**Mitigation**:
```python
def lambda_handler(event, context):
    if new_services:
        # Log all changes to CloudTrail via API calls
        # (automatically done by organizations:UpdatePolicy)
        
        # Additionally, store audit trail in DynamoDB
        audit_table.put_item(Item={
            'timestamp': datetime.utcnow().isoformat(),
            'action': 'scp_update',
            'services_added': new_services,
            'policy_id': scp_policy['id'],
            'status': 'success'
        })
```

---

## 8. Audit & Logging

### ✅ Strengths
- **CloudWatch Logs**: All executions logged
- **CloudTrail**: All API calls logged automatically
- **Log Retention**: 14 days (configurable)

### ⚠️ Considerations

#### Risk 1: Log Analysis
**Issue**: No automated alerting on errors or unusual patterns.

**Mitigation**:
```bash
# Create CloudWatch Alarm for Lambda errors
aws cloudwatch put-metric-alarm \
  --alarm-name aws-service-monitor-errors \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --dimensions Name=FunctionName,Value=aws-service-monitor \
  --statistic Sum \
  --period 300 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions arn:aws:sns:...
```

#### Risk 2: Log Injection
**Issue**: Service names logged without sanitization.

**Mitigation**:
```python
import logging

logger = logging.getLogger()

def lambda_handler(event, context):
    # Don't log user input directly
    # This is safe - service names only contain alphanumeric + hyphens
    logger.info(f"Processing {len(new_services)} services")  # Safe
    logger.debug(f"Services: {', '.join(sorted(new_services))}")  # Safe
```

---

## 9. Compliance & Governance

### ⚠️ Considerations

#### Risk 1: Change Control
**Issue**: Automated changes bypass change control processes.

**Mitigation**:
- Implement approval workflow (see section 3)
- Document in change log
- Notify teams of changes
- Maintain audit trail

#### Risk 2: Compliance Violations
**Issue**: If service blacklist is for compliance, auto-update could cause violations.

**Mitigation**:
- Validate against compliance requirements
- Test policy changes in staging first
- Have rollback procedure
- Document compliance mapping

---

## 10. Recommended Security Enhancements

### Priority 1 (Critical)
- [ ] Add HTTPS certificate validation to service reference fetch (use `requests`)
- [ ] Implement SCP update approval workflow
- [ ] Add service name validation
- [ ] Validate policy syntax before updates
- [ ] Restrict CloudWatch Logs policy to specific log group

### Priority 2 (Important)
- [ ] Store email recipients in Secrets Manager
- [ ] Enable DynamoDB point-in-time recovery
- [ ] Add CloudWatch alarms for Lambda errors
- [ ] Implement policy drift detection
- [ ] Add audit trail table to DynamoDB

### Priority 3 (Nice to Have)
- [ ] Implement dry-run mode for testing
- [ ] Add email header validation
- [ ] Enable Lambda Provisioned Concurrency
- [ ] Create custom metrics for SCP changes
- [ ] Implement CloudFormation for policy management

---

## Security Checklist for Production Deployment

```
Identity & Access
- [ ] Review all IAM policies for least privilege
- [ ] Restrict Organizations API to specific policy name
- [ ] Restrict CloudWatch Logs to specific log group
- [ ] Enable CloudTrail logging
- [ ] Audit role trust policies

Data Protection
- [ ] Enable DynamoDB point-in-time recovery
- [ ] Set appropriate CloudWatch Logs retention (30+ days)
- [ ] Enable encryption at rest (already default)
- [ ] Verify email recipients in SES
- [ ] Test email delivery

Network Security
- [ ] Verify service reference domain is reachable
- [ ] Test HTTPS certificate validation
- [ ] Confirm Lambda has outbound internet access
- [ ] Review VPC configuration (if applicable)

Service Control Policy
- [ ] Test SCP updates in staging/non-prod first
- [ ] Document approved services vs blacklisted
- [ ] Create rollback procedure
- [ ] Set up approval workflow
- [ ] Validate policy syntax

Operational
- [ ] Set up CloudWatch alarms for errors
- [ ] Configure SNS topic for alerts
- [ ] Document runbook for failures
- [ ] Test manual Lambda invocation
- [ ] Verify log group exists and has retention

Lambda
- [ ] Review code for injection vulnerabilities
- [ ] Set appropriate timeout (300s seems reasonable)
- [ ] Configure DLQ for failed invocations
- [ ] Test error handling paths
- [ ] Load test for scaling

Monitoring
- [ ] Set up dashboard for key metrics
- [ ] Create alert for policy drift
- [ ] Enable CloudTrail organization trail
- [ ] Set up SNS notifications
- [ ] Document on-call procedures

Governance
- [ ] Document change control process
- [ ] Get approval for automated changes
- [ ] Define rollback procedures
- [ ] Set audit retention policies
- [ ] Train team on system operation
```

---

## Conclusion

The solution is generally secure with proper AWS-managed service usage and IAM controls. Main concerns are:

1. **Automated SCP updates** - Add approval workflow
2. **External service reference** - Add HTTPS validation
3. **No policy drift detection** - Add monitoring
4. **Limited audit trail** - Add DynamoDB audit table

All risks are mitigatable with the recommendations above. For production use, strongly recommend implementing Priority 1 enhancements and establishing an approval workflow for SCP updates.
