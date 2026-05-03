# AWS Well-Architected Framework Review

Comprehensive assessment of the AWS Service Monitor solution against all six pillars of the AWS Well-Architected Framework.

---

## Executive Summary

| Pillar | Score | Status | Comment |
|--------|-------|--------|---------|
| **Operational Excellence** | 8/10 | 🟢 Strong | CI/CD via GitHub Actions; approval workflow adds human oversight |
| **Security** | 9/10 | 🟢 Excellent | Approval allowlist; checksum fix closes tamper-detection gap |
| **Reliability** | 8/10 | 🟢 Strong | Both DynamoDB tables have PITR; approval workflow reduces false positives |
| **Performance Efficiency** | 7/10 | 🟡 Good | Additional DynamoDB queries for approval lookup add latency |
| **Cost Optimization** | 8/10 | 🟢 Strong | Second DynamoDB table adds marginal cost; still very low overall |
| **Sustainability** | 6/10 | 🟡 Fair | Serverless is efficient; no major changes |
| **OVERALL** | **8/10** | 🟢 **EXCELLENT** | **Production-ready with strong security posture** |

---

## Pillar 1: Operational Excellence ⭐ 8/10

**Focus**: Run and monitor systems to deliver business value and continuously improve

### ✅ Strengths

1. **Infrastructure as Code**
   ```
   ✓ Full Terraform configuration
   ✓ Versioned in Git
   ✓ Reproducible deployments
   ✓ Easy to scale/modify
   ```

2. **Comprehensive Logging**
   ```
   ✓ CloudWatch Logs integration
   ✓ 14-day retention
   ✓ Structured logging with levels (INFO, ERROR, WARNING)
   ✓ Request/response logging in Lambda
   ```

3. **Documentation**
   ```
   ✓ README.md - Project overview
   ✓ DEPLOYMENT_GUIDE.md - Step-by-step setup
   ✓ BASELINE_INITIALIZATION.md - Feature guide
   ✓ DEVELOPMENT.md - Customization guide
   ✓ SECURITY.md - Security controls
   ✓ ARCHITECTURE.md - Diagrams & design
   ✓ runbooks/ - Operational procedures (SCP rollback, DynamoDB recovery, Lambda timeout)
   ```

4. **Error Handling**
   ```
   ✓ Try/catch blocks in Lambda
   ✓ Graceful degradation
   ✓ Detailed error messages
   ✓ Exception logging
   ```

5. **Automation**
   ```
   ✓ EventBridge scheduling
   ✓ Automatic service baseline initialization
   ✓ Conditional writes prevent race conditions
   ✓ Approval workflows (manual trigger option)
   ```

6. **CI/CD Pipeline** ✅ [NEW]
   ```
   ✓ GitHub Actions workflows using anthropics/claude-code-action@v1
   ✓ Automated code review on every pull request (claude-code-review.yml)
   ✓ On-demand Claude assistance via @claude mentions in issues and PRs (claude.yml)
   ✓ CI results surfaced directly in PRs for fast feedback loops
   ✓ Reduces manual review burden; flags issues before merge
   ```

7. **Service Approval Workflow** ✅ [NEW]
   ```
   ✓ Human oversight gate before new services affect the SCP deny list
   ✓ Approval request emails sent to configurable approval_recipients list
   ✓ Pending approvals tracked in DynamoDB for audit trail
   ✓ Operators can approve via terraform.tfvars without code changes
   ✓ Reduces toil from spurious SCP additions
   ```

### ⚠️ Gaps

1. **No Operational Dashboards**
   ```
   ✗ No CloudWatch Dashboard
   ✗ No real-time metrics visualization
   ✗ No KPI tracking (services detected, SCP updates)
   ✗ No health status overview
   ```

2. **Limited Alerting**
   ```
   ✗ No CloudWatch Alarms configured
   ✗ No alert on high Lambda error rate
   ✗ No alert on missed executions
   ```

3. **No Performance Tuning Guidelines**
   ```
   ✗ No guidance on Lambda memory sizing
   ✗ No guidance on DynamoDB scaling
   ✗ No performance benchmarks
   ```

4. **No Change Management**
   ```
   ✗ No change log
   ✗ No deployment tracking
   ✗ No rollback procedures documented
   ```

5. **Approval Workflow UX**
   ```
   ✗ No self-service approval UI (approval requires terraform.tfvars edit + apply)
   ✗ No approval expiry / timeout handling
   ✗ No automatic reminder emails for pending approvals
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```hcl
# Add CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "service-monitor"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Lambda", "Invocations", {"stat": "Sum"}],
            ["AWS/Lambda", "Errors", {"stat": "Sum"}],
            ["AWS/Lambda", "Duration", {"stat": "Average"}]
          ]
        }
      }
    ]
  })
}
```

**Priority 2 (Medium)**:
```hcl
# Add CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "service-monitor-errors"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  period              = "3600"
  threshold           = "1"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

**Priority 3 (Medium)**:
```markdown
# Improve approval workflow ergonomics
- Add approval expiry (e.g., auto-escalate after 7 days with no decision)
- Consider a lightweight approval API (API Gateway + Lambda) to replace
  the terraform.tfvars edit workflow, enabling one-click approval from email
```

---

## Pillar 2: Security ⭐ 9/10

**Focus**: Protect information, systems, and assets

### ✅ Strengths

1. **Identity and Access Management**
   ```
   ✓ IAM role with least privilege
   ✓ Scoped DynamoDB access (covers both tables and the GSI)
   ✓ Scoped CloudWatch Logs access
   ✓ Resource-specific permissions
   ✓ Service principal authentication
   ✓ No hardcoded credentials
   ```

2. **Data Protection**
   ```
   ✓ DynamoDB encrypted at rest (AWS managed keys)
   ✓ TLS 1.2+ for API calls (enforced)
   ✓ HTTPS certificate validation on service fetch
   ✓ CloudWatch Logs encrypted
   ✓ No sensitive data in transit
   ```

3. **Input Validation**
   ```
   ✓ Service name format validation
   ✓ Service name length validation
   ✓ SCP policy syntax validation
   ✓ Email address validation (via SES)
   ✓ JSON schema validation
   ✓ HTML output escaped via html.escape() in approval emails
   ```

4. **Application Security**
   ```
   ✓ Conditional writes prevent race conditions
   ✓ Approval workflow for SCP policy changes
   ✓ Service reference fetch with SSL validation
   ✓ No SQL injection possible (DynamoDB)
   ✓ No command injection possible
   ```

5. **Compliance & Audit**
   ```
   ✓ CloudTrail logging of all API calls
   ✓ DynamoDB point-in-time recovery (service registry)
   ✓ DynamoDB point-in-time recovery (approved services table) ✅ NEW
   ✓ Service registry immutable records
   ✓ Baseline initialization tracking
   ✓ Approval audit trail in DynamoDB (pending / approved status) ✅ NEW
   ```

6. **Secret Management**
   ```
   ✓ No secrets in code/config
   ✓ IAM roles for service credentials
   ✓ Email recipients in environment variables
   ✓ No hardcoded API keys/tokens
   ```

7. **Baseline Integrity** ✅ [T004 IMPLEMENTED]
   ```
   ✓ SHA256 checksum verification of baseline services
   ✓ Detects unauthorized DynamoDB modifications
   ✓ S3 immutable snapshots with Object Lock (90-day retention)
   ✓ Automatic tamper alerts via email and SNS
   ✓ Forensic evidence preservation and recovery capability
   ✓ Two-layer protection against baseline reinitialization attacks
   ```

8. **Checksum Consistency Fix** ✅ [NEW]
   ```
   ✓ update_baseline_checksum() called immediately after store_new_services()
   ✓ Closes the window where legitimate service additions would trigger
     false tamper alerts on the next execution
   ✓ Prevents operational disruption caused by benign checksum drift
   ```

9. **Service Approval Allowlist** ✅ [NEW]
   ```
   ✓ Approved services are tracked in DynamoDB but excluded from the SCP deny list
   ✓ Approval decisions are an explicit, auditable human action
   ✓ Per-service approval emails sent to configurable approval_recipients list
   ✓ Two sources of truth: terraform.tfvars (static) + DynamoDB table (dynamic)
   ✓ DynamoDB GSI on approval_status enables efficient policy-based queries
   ✓ Lambda IAM policy explicitly grants access to the GSI endpoint
   ```

### ⚠️ Gaps

1. **Encryption Key Management**
   ```
   ✗ DynamoDB uses AWS managed keys (not KMS) — applies to both tables
   ✗ No customer-managed encryption keys
   ✗ No key rotation control
   ✗ No key access audit trail
   ```

2. **Secrets Management**
   ```
   ✗ Email recipients in plaintext environment variables
   ✗ Not stored in AWS Secrets Manager
   ✗ Not using Parameter Store
   ✗ Visible in Lambda console
   ```

3. **Network Security**
   ```
   ✗ No VPC configuration (Lambda has public internet)
   ✗ No security groups (not in VPC)
   ✗ No network ACLs
   ✗ No private endpoints for AWS services
   ✗ No egress filtering
   ```

4. **Monitoring & Detection**
   ```
   ✗ No GuardDuty integration
   ✗ No Security Hub integration
   ✗ No anomaly detection
   ✗ No behavior analysis
   ✗ No threat detection
   ```

5. **Approval Workflow Integrity**
   ```
   ✗ Approval status in DynamoDB could theoretically be modified directly
     (though this would require IAM permissions the Lambda role already has)
   ✗ No separate IAM principal with read-only approval access
   ✗ No approval expiry — pending items accumulate indefinitely
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```hcl
# Use AWS Secrets Manager for email recipients
resource "aws_secretsmanager_secret" "email_config" {
  name = "service-monitor/email-config"
}

resource "aws_secretsmanager_secret_version" "email_config" {
  secret_id = aws_secretsmanager_secret.email_config.id
  secret_string = jsonencode({
    recipients = var.email_recipients
    sender     = var.sender_email
  })
}
```

**Priority 2 (Medium)**:
```hcl
# Use KMS for DynamoDB encryption (both tables)
resource "aws_kms_key" "dynamodb" {
  description             = "KMS key for DynamoDB encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_dynamodb_table" "approved_services" {
  # ... existing config ...
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }
}
```

**Priority 3 (Medium)**:
```hcl
# Add GuardDuty and Security Hub integration
resource "aws_securityhub_account" "main" {
  enable_default_standards = true
}

resource "aws_guardduty_detector" "main" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
  }
}
```

**Implementation Status**: ✅ Baseline integrity verification (T004) is now fully implemented with:
- SHA256 checksum validation on every execution
- Checksum updated after legitimate service additions (eliminates false tamper alerts)
- S3 immutable snapshots with Object Lock
- Automatic tamper detection and alerting (email + SNS)
- See [T004_IMPLEMENTATION.md](../threat-model/T004_IMPLEMENTATION.md) for details

---

## Pillar 3: Reliability ⭐ 8/10

**Focus**: Ensure workloads perform intended functions and recover from failures

### ✅ Strengths

1. **Fault Tolerance**
   ```
   ✓ Service fetch failures handled gracefully
   ✓ DynamoDB failures don't stop Lambda
   ✓ SCP update failures reported but don't cascade
   ✓ Email send failures logged but don't block
   ✓ Partial failure handling (some services fail but others succeed)
   ✓ Approval table query failure degrades gracefully (returns pre-configured list)
   ```

2. **Data Persistence**
   ```
   ✓ DynamoDB point-in-time recovery on service registry (35 days)
   ✓ DynamoDB point-in-time recovery on approved services table (35 days) ✅ NEW
   ✓ Service registry stored persistently
   ✓ Baseline marked and versioned
   ✓ Audit trail maintained
   ✓ No data loss on Lambda failure
   ```

3. **Lambda Configuration**
   ```
   ✓ 300-second timeout (adequate)
   ✓ 512MB memory (sufficient)
   ✓ Dead letter queue option available
   ✓ Automatic retries (EventBridge)
   ✓ Error logging to CloudWatch
   ```

4. **Availability**
   ```
   ✓ Managed services (no infrastructure to manage)
   ✓ Multi-AZ DynamoDB (automatic)
   ✓ Multi-AZ Lambda (automatic)
   ✓ 99.9% SLA (Lambda, DynamoDB, EventBridge)
   ✓ Auto-scaling DynamoDB on-demand
   ```

5. **Backup & Recovery**
   ```
   ✓ DynamoDB PITR enabled on both tables
   ✓ Service registry recoverable
   ✓ Approved services recoverable independently of service registry
   ✓ Baseline recoverable
   ✓ 35-day recovery window
   ✓ Point-in-time restore capability
   ```

6. **Reduced False Positives** ✅ [NEW]
   ```
   ✓ update_baseline_checksum() prevents spurious integrity violations
     after legitimate service additions
   ✓ Approval workflow prevents legitimate new services from generating
     unnecessary SCP changes that must be rolled back
   ✓ Approved services excluded from SCP deny list automatically
   ```

### ⚠️ Gaps

1. **Multi-Region Setup**
   ```
   ✗ Single region deployment (eu-west-2 only)
   ✗ No failover capability
   ✗ No disaster recovery across regions
   ✗ Regional outage = total unavailability
   ```

2. **High Availability**
   ```
   ✗ No active-active setup
   ✗ No data replication to another region
   ✗ No cross-region failover
   ✗ RTO/RPO not defined
   ```

3. **Alerting & Monitoring**
   ```
   ✗ No CloudWatch Alarms for failures
   ✗ No Dashboard for health status
   ✗ No health check endpoint
   ✗ No synthetic monitoring
   ```

4. **Testing**
   ```
   ✗ No integration tests
   ✗ No failure injection tests
   ✗ No recovery procedure tests
   ✗ No load testing
   ✗ No chaos engineering
   ```

5. **Graceful Degradation**
   ```
   ✗ No circuit breaker pattern
   ✗ No request throttling
   ✗ No rate limiting
   ✗ No fallback mechanisms
   ```

6. **Approval Table Resilience**
   ```
   ✗ If the approved services table is unavailable, Lambda falls back to
     the static APPROVED_SERVICES_LIST only — unapproved new services will
     still trigger SCP additions, which is the safe-fail direction but may
     cause unexpected SCP changes during a table outage
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```hcl
# Add CloudWatch Alarms for reliability
resource "aws_cloudwatch_metric_alarm" "lambda_timeout" {
  alarm_name  = "service-monitor-timeout"
  metric_name = "Duration"
  namespace   = "AWS/Lambda"
  threshold   = "270000"  # 270 seconds (90% of 300s timeout)
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name  = "service-monitor-dynamodb-throttle"
  metric_name = "UserErrors"
  namespace   = "AWS/DynamoDB"
  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

**Priority 2 (Medium)**:
```hcl
# Add Dead Letter Queue for failed invocations
resource "aws_sqs_queue" "lambda_dlq" {
  name = "service-monitor-dlq"

  message_retention_seconds = 1209600  # 14 days
}

resource "aws_lambda_function" "service_monitor" {
  # ... existing config ...
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
}
```

**Priority 3 (Medium)**:
```markdown
# Define RTO/RPO objectives
- RTO (Recovery Time Objective): 1 hour
- RPO (Recovery Point Objective): 1 day

# Document recovery procedures
- DynamoDB table restore from PITR (both tables)
- Lambda function redeploy from Git
- EventBridge rule recreation
- Approved services table restore procedure
```

---

## Pillar 4: Performance Efficiency ⭐ 7/10

**Focus**: Use computing resources efficiently and maintain performance

### ✅ Strengths

1. **Appropriate Service Selection**
   ```
   ✓ Lambda for event-driven processing (not always running)
   ✓ DynamoDB on-demand for variable load
   ✓ EventBridge for scheduling (no infrastructure)
   ✓ SES for email (fully managed)
   ✓ Organizations API (no additional compute)
   ```

2. **Lambda Optimization**
   ```
   ✓ 512MB memory (good balance of cost/performance)
   ✓ Python 3.11 (latest, best performance)
   ✓ ~10-20 second execution time
   ✓ Efficient batch operations (DynamoDB)
   ✓ Connection pooling (boto3)
   ```

3. **DynamoDB Optimization**
   ```
   ✓ Pay-per-request billing (no over-provisioning)
   ✓ Automatic scaling
   ✓ Batch writes (batch_writer API)
   ✓ Efficient queries
   ✓ Projection expressions (limit returned data)
   ✓ GSI on approval_status enables efficient status queries ✅ NEW
   ```

4. **Network Efficiency**
   ```
   ✓ Requests library (efficient HTTP)
   ✓ Connection reuse (urllib3 pooling)
   ✓ HTTPS with certificate validation
   ✓ Efficient DynamoDB queries
   ```

5. **Code Efficiency**
   ```
   ✓ Minimal dependencies (boto3, requests, stdlib)
   ✓ No unnecessary loops
   ✓ Set operations for service comparison (O(n))
   ✓ Efficient filtering
   ✓ Early returns to save processing
   ```

### ⚠️ Gaps

1. **Additional DynamoDB Queries (Approval Workflow)** [NEW]
   ```
   ⚠ get_approved_services() adds a DynamoDB Query call on every execution
     that detects new services (one Query against the GSI)
   ⚠ track_service_for_approval() adds one PutItem per unapproved service
   ⚠ send_approval_request_email() adds one SES send per unapproved service
   ⚠ Acceptable for daily/low-frequency use but adds 50-200ms latency per call
   ```

2. **Caching**
   ```
   ✗ No Lambda layer caching
   ✗ No service list caching
   ✗ No policy document caching
   ✗ No request memoization
   ✗ Approved services list re-fetched on every invocation
   ```

3. **Lambda Configuration**
   ```
   ✗ No memory scaling based on load
   ✗ No Provisioned Concurrency (for consistent latency)
   ✗ No Lambda Layers (for code reuse)
   ✗ No code minification
   ```

4. **DynamoDB**
   ```
   ✗ Service registry still uses Scan for some operations (no GSI for is_baseline)
   ✗ No TTL on old entries
   ✗ No caching strategy for approved services
   ```

5. **API Performance**
   ```
   ✗ No request batching for Organizations API
   ✗ No pagination optimization
   ✗ No rate limiting handling
   ```

6. **Monitoring**
   ```
   ✗ No performance metrics dashboard
   ✗ No latency tracking
   ✗ No throughput monitoring
   ✗ No performance regression detection
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```python
# Cache approved services in Lambda execution context
# (valid across warm invocations within the same day)
_approved_services_cache = None

def get_approved_services() -> Set[str]:
    global _approved_services_cache
    if _approved_services_cache is not None:
        return _approved_services_cache
    # ... existing fetch logic ...
    _approved_services_cache = approved
    return approved
```

**Priority 2 (Medium)**:
```hcl
# Add DynamoDB Global Secondary Index for baseline queries
resource "aws_dynamodb_table" "service_registry" {
  # ... existing config ...

  global_secondary_index {
    name            = "is_baseline-index"
    hash_key        = "is_baseline"
    range_key       = "service_name"
    projection_type = "KEYS_ONLY"
  }
}
```

**Priority 3 (Medium)**:
```python
# Add CloudWatch Logs Insights queries for performance
# Query execution time distribution
fields @duration | stats avg(@duration), max(@duration), pct(@duration, 95)

# Query DynamoDB API calls
fields @duration | filter @message like /DynamoDB/ | stats count()
```

---

## Pillar 5: Cost Optimization ⭐ 8/10

**Focus**: Run systems to deliver business value at lowest price point

### ✅ Strengths

1. **Appropriate Pricing Models**
   ```
   ✓ Lambda: Pay-per-invocation (~$0.20/month)
   ✓ DynamoDB: On-demand billing on both tables (~$1.00-2.00/month combined)
   ✓ EventBridge: Free (no charge for triggers)
   ✓ SES: Pay-per-email (~$0.10/month; approval emails add marginal cost)
   ✓ CloudWatch: Free tier covers usage
   ✓ Organizations: API included
   ```

2. **Right-Sizing**
   ```
   ✓ 512MB Lambda memory (adequate, not over-provisioned)
   ✓ 300-second timeout (not excessive)
   ✓ DynamoDB on-demand (scales with usage)
   ✓ Single daily execution (minimal invocations)
   ✓ No unnecessary compute
   ```

3. **Cost Avoidance**
   ```
   ✓ Serverless (no EC2/RDS idle costs)
   ✓ No storage costs (DynamoDB included)
   ✓ No bandwidth costs (internal AWS APIs)
   ✓ No infrastructure overhead
   ✓ No management burden
   ```

4. **Efficient Operations**
   ```
   ✓ Automated deployments (Terraform)
   ✓ No manual operational overhead
   ✓ No DBA required
   ✓ No system administration
   ✓ Auto-scaling (no manual tuning)
   ```

5. **Cost Tracking**
   ```
   ✓ Predictable costs (fixed schedule)
   ✓ Easy to estimate (~$2-3/month baseline with new table)
   ✓ Cost per service tiny
   ✓ No surprise charges
   ```

### ⚠️ Gaps

1. **Second DynamoDB Table Cost** [NEW]
   ```
   ⚠ aws-service-monitor-approved-services adds a second on-demand table
   ⚠ Marginal additional cost (~$0.25/month); PITR on both tables adds
     ~$0.20/GB/month (negligible at current data volume)
   ⚠ Approval request emails via SES add per-email cost for each unapproved
     new service; low frequency so impact is minimal
   ```

2. **Cost Monitoring**
   ```
   ✗ No AWS Cost Explorer integration
   ✗ No budget alerts
   ✗ No cost anomaly detection
   ✗ No per-component cost tracking
   ✗ No cost allocation tags
   ```

3. **Reserved Capacity**
   ```
   ✗ Not using Reserved Capacity (Lambda)
   ✗ Not using Savings Plans
   ✗ Using on-demand only
   ```

4. **Cost Optimization Opportunities**
   ```
   ✗ No Lambda memory auto-tuning
   ✗ No Spot Lambda usage
   ✗ No Reserved DynamoDB capacity
   ✗ Not using Compute Savings Plans
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```hcl
# Add cost allocation tags
locals {
  cost_tags = {
    CostCenter  = "Security"
    Service     = "AWS-Service-Monitor"
    Owner       = "Platform-Team"
    Environment = "Production"
  }
}

resource "aws_dynamodb_table" "approved_services" {
  # ... existing config ...
  tags = merge(var.tags, local.cost_tags)
}
```

**Priority 2 (Medium)**:
```hcl
# Add budget alert
resource "aws_budgets_budget" "service_monitor" {
  name              = "service-monitor-monthly"
  budget_type       = "MONTHLY"
  limit_amount      = "10.00"  # Alert if > $10/month
  limit_unit        = "USD"
  time_period_start = "2026-05-01"

  notification {
    comparison_operator    = "GREATER_THAN"
    notification_type      = "FORECASTED"
    threshold              = "100"
    threshold_type         = "PERCENTAGE"
    notification_frequency = "DAILY"
  }
}
```

**Priority 3 (Low)**:
```bash
# Monitor costs
aws ce get-cost-and-usage \
  --time-period Start=2026-05-01,End=2026-05-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter file://cost-filter.json
```

---

## Pillar 6: Sustainability ⭐ 6/10

**Focus**: Minimize environmental impact and understand your carbon footprint

### ✅ Strengths

1. **Serverless Architecture**
   ```
   ✓ Lambda functions (100% serverless)
   ✓ No idle server instances
   ✓ AWS handles infrastructure efficiency
   ✓ Minimal physical footprint
   ✓ Shared AWS infrastructure
   ```

2. **Efficient Resource Usage**
   ```
   ✓ Only runs when needed (daily schedule)
   ✓ Completes quickly (~10-20 seconds)
   ✓ Minimal compute usage
   ✓ On-demand DynamoDB (only what's used)
   ✓ No over-provisioning
   ```

3. **Code Efficiency**
   ```
   ✓ Python (efficient language)
   ✓ Minimal dependencies
   ✓ Small memory footprint
   ✓ Quick startup time
   ✓ No long-running processes
   ```

### ⚠️ Gaps

1. **Sustainability Metrics**
   ```
   ✗ No carbon footprint tracking
   ✗ No energy consumption metrics
   ✗ No sustainability dashboard
   ✗ No reporting
   ```

2. **Regional Optimization**
   ```
   ✗ No low-carbon region preference
   ✗ No renewable energy optimization
   ✗ Fixed to eu-west-2
   ```

3. **Data Retention**
   ```
   ✗ No data lifecycle management
   ✗ No cleanup of old entries
   ✗ Indefinite DynamoDB storage (approved services table also has no TTL)
   ✗ CloudWatch Logs kept for 14 days (good, but could be shorter)
   ✗ Pending approval items accumulate in DynamoDB with no expiry
   ```

4. **Sustainability Reporting**
   ```
   ✗ No AWS Carbon Dashboard integration
   ✗ No sustainability reporting
   ✗ No per-service carbon tracking
   ```

### 🔧 Recommendations

**Priority 1 (High)**:
```hcl
# Optimize CloudWatch Logs retention
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/aws-service-monitor"
  retention_in_days = 7  # Reduce from 14 days

  tags = var.tags
}
```

**Priority 2 (Medium)**:
```python
# Add TTL for resolved approval items (keeps table lean)
def track_service_for_approval(service_name: str, timestamp: str) -> bool:
    """Record a new service as pending approval with TTL for cleanup."""
    import time
    ttl_timestamp = int(time.time()) + (90 * 86400)  # 90 days
    table.put_item(Item={
        'service_name': service_name,
        'approval_status': 'pending',
        'detected_at': timestamp,
        'ttl': ttl_timestamp  # Auto-expire stale pending items
    })
```

**Priority 3 (Medium)**:
```bash
# Use AWS Carbon Dashboard to track emissions
# Visit: https://console.aws.amazon.com/billing/home#/carbon-dashboard

# Option: Use low-carbon regions if multi-region
# us-west-2: 25g CO2 per vCPU-hour
# eu-north-1: 10g CO2 per vCPU-hour (best)
```

---

## Overall Assessment

### Scoring Summary

```
┌──────────────────────────────────────────────┐
│        AWS Well-Architected Score             │
├──────────────────────────────────────────────┤
│ Operational Excellence:  8/10 🟢 Strong      │
│ Security:                9/10 🟢 Excellent   │
│ Reliability:             8/10 🟢 Strong      │
│ Performance Efficiency:  7/10 🟡 Good        │
│ Cost Optimization:       8/10 🟢 Strong      │
│ Sustainability:          6/10 🟡 Fair        │
├──────────────────────────────────────────────┤
│ OVERALL:                 8/10 🟢 EXCELLENT   │
└──────────────────────────────────────────────┘
```

### Production Readiness

**Status**: ✅ **PRODUCTION READY**

The solution demonstrates strong adherence to AWS Well-Architected principles with solid implementation across most pillars. Security and reliability are particularly strong following the recent additions, while performance efficiency and sustainability have room for improvement.

### Critical Strengths

1. **Security** (9/10) — MAINTAINED
   - Baseline integrity verification (T004)
   - Checksum updated after legitimate service additions (eliminates false tamper alerts)
   - Service approval allowlist with DynamoDB audit trail
   - Excellent IAM implementation (GSI endpoint explicitly granted)
   - Strong input validation including HTML escaping in approval emails
   - No hardcoded credentials

2. **Operational Excellence** (8/10) ⬆️ IMPROVED
   - CI/CD via GitHub Actions (automated PR review + on-demand Claude assistance)
   - Service approval workflow reduces manual toil and operational incidents
   - Operational runbooks added for common failure scenarios

3. **Reliability** (8/10) ⬆️ IMPROVED
   - PITR enabled on both DynamoDB tables
   - Approval workflow prevents incorrect SCP changes that would require rollback
   - Checksum fix eliminates a class of false-positive failures

### Key Gaps to Address

1. **Performance Efficiency** (7/10) — WATCH
   - Approval workflow adds ~50-200ms of additional DynamoDB/SES calls per execution
   - Consider caching the approved services list across warm Lambda invocations
   - Pending approvals accumulate in DynamoDB with no TTL

2. **Operational Excellence** (8/10)
   - Add CloudWatch Dashboard and Alarms
   - Improve approval workflow ergonomics (expiry, reminder emails)

3. **Sustainability** (6/10)
   - Add TTL to approval records
   - Track carbon footprint

### Implementation Priority

**Phase 1 (Immediate - Week 1)**:
```
✓ Add CloudWatch Dashboard
✓ Configure CloudWatch Alarms (errors, timeout, throttles)
✓ Add TTL to approved services / pending approval items
✓ Add cost allocation tags to both DynamoDB tables
⏱️ Effort: 4 hours
```

**Phase 2 (Soon - Month 1)**:
```
✓ Use AWS Secrets Manager for email config
✓ Enable KMS encryption for both DynamoDB tables
✓ Cache approved services list in Lambda execution context
✓ Define RTO/RPO objectives
✓ Add budget alert ($10/month threshold)
⏱️ Effort: 8 hours
```

**Phase 3 (Future - Quarter 2)**:
```
✓ GuardDuty integration for threat detection
✓ Security Hub integration for compliance monitoring
✓ Lightweight approval API (API Gateway + Lambda) for one-click email approval
✓ Add multi-region setup (optional)
✓ Add cost anomaly detection
✓ Carbon footprint tracking
⏱️ Effort: 12+ hours
```

**Completed Items**:
```
✅ Baseline integrity verification (T004 - DynamoDB tampering protection)
   - SHA256 checksum verification
   - S3 immutable snapshots with Object Lock
   - Automated tamper detection and alerting (email + SNS)
✅ update_baseline_checksum() — prevents false tamper alerts after new service additions
✅ Service approval / allowlist workflow
   - approved-services DynamoDB table with GSI on approval_status
   - get_approved_services(), track_service_for_approval(), send_approval_request_email()
   - Approved services excluded from SCP deny list
   - PITR enabled on approval table
✅ GitHub Actions CI/CD workflows
   - claude-code-review.yml — automated PR review on every open/sync/reopen
   - claude.yml — on-demand Claude assistance via @claude mentions
✅ main.tf bug fixes
   - Correct point_in_time_recovery block name
   - filter {} block in S3 lifecycle rule
   - Removed reserved AWS_REGION environment variable
```

---

## Conclusion

The AWS Service Monitor is an **excellently-architected solution** that demonstrates strong alignment with AWS best practices across all pillars. The recent additions materially strengthen three pillars:

- **Operational Excellence**: GitHub Actions CI/CD removes a manual review gap and the approval workflow adds a human oversight gate that reduces operational incidents.
- **Security**: The checksum fix closes a false-positive gap in tamper detection; the approval allowlist adds an explicit, auditable control over which services reach the SCP deny list.
- **Reliability**: PITR on the second DynamoDB table and the checksum fix together reduce the blast radius of both accidental and malicious changes.

**Current Status**: 8/10 overall — strong across all pillars with no critical gaps.

The solution is **production-ready for enterprise deployments**. With the recommended Phase 1 improvements (operational dashboards, TTL on approval records, cost tags), the estimated score rises to **8.5/10**. Phase 2 improvements (KMS encryption, Secrets Manager, approved-services caching) would further elevate it to a **9/10** readiness level.
