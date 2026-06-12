# Security Considerations & Review

This document outlines security risks, mitigations, and best practices for the AWS Service Monitor solution.

*Last reviewed: 2026-05-03. Covers lambda/index.py, main.tf, and GitHub Actions workflows including the service approval workflow, baseline checksum fix, and CI/CD pipeline.*

---

## Executive Summary

**Risk Level**: MEDIUM (with implementation gap noted below)

The solution uses AWS-managed services with proper IAM controls. All Priority 1 recommendations from the prior review have been implemented: HTTPS certificate validation is in place, service name validation is enforced, policy syntax is validated before updates, CloudWatch Logs are scoped to the specific log group, and DynamoDB point-in-time recovery is enabled. A service approval/allowlist workflow has been added. One code defect (`MANAGE_SCP_POLICY` undefined at module level — see Section 3) will cause a runtime `NameError` when new services are detected; this should be treated as a high-priority fix.

---

## 1. Identity & Access Control (IAM)

### Strengths
- **No Hardcoded Credentials**: Uses IAM roles assumed by Lambda.
- **Least Privilege Principle**: Each IAM policy grants only the required permissions.
- **Separate Role**: Lambda has a dedicated execution role.
- **Trust Policy**: Only the Lambda service principal can assume the role.
- **Resource-Specific S3 Access**: The Lambda S3 policy is scoped to the specific bucket ARN.
- **SNS Policy Scoped**: `sns:Publish` is restricted to the specific alerts topic ARN.
- **CloudWatch Logs Scoped**: Logs policy uses `${aws_cloudwatch_log_group.lambda_logs.arn}:*` — the fix recommended in the prior review is implemented.
- **DynamoDB Scoped**: Policy covers exactly the two required table ARNs (service registry + approved services) plus the GSI path.

### Residual Risks

#### Risk 1: Organizations API — Wildcard Resource (AWS Limitation)
**Severity**: LOW (acknowledged AWS constraint)

`organizations:ListPolicies`, `organizations:DescribePolicy`, and `organizations:UpdatePolicy` require `"Resource": "*"` because the Organizations API does not support resource-level ARN conditions at the policy statement level.

**Mitigation**: Add a condition to narrow the blast radius to the named SCP:
```json
{
  "Effect": "Allow",
  "Action": ["organizations:ListPolicies", "organizations:DescribePolicy", "organizations:UpdatePolicy"],
  "Resource": "*",
  "Condition": {
    "StringEquals": { "organizations:PolicyName": "blacklist" }
  }
}
```
Monitor CloudTrail for unexpected `UpdatePolicy` calls.

#### Risk 2: SES Permissions — Wildcard Resource (AWS Limitation)
**Severity**: LOW (acknowledged AWS constraint)

`ses:SendEmail` and `ses:SendRawEmail` cannot be narrowed by resource ARN in a role policy. Optionally add a sender-address condition:
```json
{
  "Effect": "Allow",
  "Action": ["ses:SendEmail", "ses:SendRawEmail"],
  "Resource": "*",
  "Condition": {
    "StringEquals": { "ses:FromAddress": "aws-monitor@example.com" }
  }
}
```

#### Risk 3: CloudWatch Metrics — Wildcard Resource (AWS Limitation)
**Severity**: LOW (acknowledged AWS constraint)

`cloudwatch:PutMetricData` requires `"Resource": "*"`. The custom namespace `AWS/ServiceMonitor` contains no sensitive data. No additional mitigation available.

#### Risk 4: Approved Services Table — Missing DeleteItem Permission
**Severity**: INFO

The DynamoDB policy grants `GetItem`, `PutItem`, `UpdateItem`, `Query`, and `Scan`. Approval records written by `track_service_for_approval()` cannot be deleted by Lambda. If future cleanup is needed (e.g., removing stale pending records), `dynamodb:DeleteItem` will need to be added. This is currently correct by design (no delete path in the code) but should be noted for future development.

---

## 2. Data Protection

### Strengths
- **DynamoDB Encryption**: AWS-managed keys by default on both tables.
- **DynamoDB PITR**: Point-in-time recovery is enabled on both the service registry and approved services tables (prior recommendation implemented).
- **TLS in Transit**: All AWS API calls use TLS 1.2+.
- **No Sensitive Data in Registry**: Service registry stores only service names.
- **S3 Baseline Bucket**: Server-side encryption (AES256), versioning enabled, public access fully blocked, 90-day GOVERNANCE object lock for immutability.
- **S3 Lifecycle**: Snapshots expire after 365 days; non-current versions after 90 days.

### Residual Risks

#### Risk 1: CloudWatch Logs Retention
**Severity**: LOW

14-day retention may be insufficient for compliance or forensic requirements. Adjust to 30–90 days:
```hcl
resource "aws_cloudwatch_log_group" "lambda_logs" {
  retention_in_days = 90
}
```

#### Risk 2: Approved Services Table — No Encryption Key Specified
**Severity**: LOW

The `approved_services` DynamoDB table uses AWS-managed encryption by default, which is acceptable. If compliance requires customer-managed keys (CMK), add:
```hcl
server_side_encryption {
  enabled     = true
  kms_key_arn = aws_kms_key.dynamodb.arn
}
```

#### Risk 3: Email Recipients in Environment Variables
**Severity**: LOW

`EMAIL_RECIPIENTS`, `APPROVAL_RECIPIENTS`, and `SENDER_EMAIL` are stored in Lambda environment variables, visible in the Lambda console and CloudTrail `UpdateFunctionConfiguration` events. These are not secrets (they are email addresses), but if your threat model includes insider threats with console access, consider moving them to SSM Parameter Store.

#### Risk 4: Service Reference Fetch — HTTPS Now Enforced (Prior Issue Resolved)
**Severity**: RESOLVED

The prior risk (missing SSL verification) is resolved. The code uses `requests.get(..., verify=True)` with explicit `SSLError` handling. The `requests` library is in `lambda/requirements.txt`.

---

## 3. Service Control Policy Management

### Strengths
- **Approval Gate**: `REQUIRE_APPROVAL = true` by default; when set, SCP changes are stored as pending and not applied automatically.
- **Policy Syntax Validation**: `validate_policy_document()` checks structure and JSON serializability before any `UpdatePolicy` call.
- **Service Name Validation**: `validate_service_names()` enforces lowercase alphanumeric + hyphens, minimum length 2, maximum length 30 before any service reaches the SCP.
- **HTML Escaping**: Service names are escaped with `html.escape()` before insertion into email bodies.
- **Deep Copy Before Mutation**: `update_scp_with_services()` works on a `copy.deepcopy()` of the policy, so the original is never mutated before validation succeeds.

### Active Issues

#### Issue 1: MANAGE_SCP_POLICY Undefined — Runtime NameError
**Severity**: HIGH

`lambda/index.py` references `MANAGE_SCP_POLICY` at line 1111 inside `lambda_handler()`, but this variable is never defined at module level (it is not in the `os.environ` parsing block at lines 22–32, and it is not set as a Terraform environment variable in `main.tf`). On any execution where new services are detected, the code will raise a `NameError: name 'MANAGE_SCP_POLICY' is not defined`, causing the Lambda to return HTTP 500 and leaving new services tracked in DynamoDB but the SCP unmodified.

**Fix**: Add to `lambda/index.py` module-level env var block:
```python
MANAGE_SCP_POLICY = os.environ.get('MANAGE_SCP_POLICY', 'true').lower() == 'true'
```
And add to the `environment` block in `main.tf`:
```hcl
MANAGE_SCP_POLICY = var.manage_scp_policy ? "true" : "false"
```

#### Risk 2: Approval Workflow — No Approver Authentication
**Severity**: MEDIUM

The approval workflow (`send_approval_request_email`, `track_service_for_approval`) records services as `pending` in DynamoDB and instructs approvers to manually edit `terraform.tfvars` and run `terraform apply`. There is no in-band approval mechanism (no signed token, no step function callback). Any person with write access to `terraform.tfvars` can approve services, and the system has no record of who approved what.

**Mitigation**: For audit compliance, document that approval is via Terraform PR review (Git history serves as the audit trail). If stronger attribution is required, implement a Step Functions human-approval pattern or an SNS-to-Lambda approval callback.

#### Risk 3: Approved Services List in Environment Variables
**Severity**: LOW

`APPROVED_SERVICES_LIST` is stored in Lambda environment variables (sourced from `var.approved_services` in `terraform.tfvars`). This list is visible in the Lambda console. Approved services are not sensitive, but any change to the list requires `terraform apply`, which provides an implicit change-control record via Git.

#### Risk 4: Service Reference Data Integrity
**Severity**: MEDIUM (unchanged from prior review)

The system trusts the AWS service reference endpoint at `https://servicereference.eu-west-2.amazonaws.com/` without a secondary integrity check. If AWS temporarily returns malformed or unexpected data, the service name validator (`SERVICE_NAME_PATTERN`, `MAX_SERVICE_NAME_LENGTH`) provides a first line of defence by rejecting names that do not match the expected format. Consider also alerting when the number of newly detected services in a single run exceeds a threshold (e.g., more than 10), as a large batch could indicate a data anomaly:
```python
MAX_NEW_SERVICES_PER_RUN = int(os.environ.get('MAX_NEW_SERVICES_PER_RUN', '10'))
if len(valid_services) > MAX_NEW_SERVICES_PER_RUN:
    logger.error(f"Anomaly: {len(valid_services)} new services in one run, aborting")
    return {'statusCode': 400, ...}
```

#### Risk 5: SCP Statement Targeting — Sid-Based Selection
**Severity**: INFO

The code in `update_scp_with_services()` finds the statement to update by looking for the first `"Effect": "Deny"` statement. The `scp_sid` variable and `SCP_SID` env var exist but are not used in the statement lookup logic — the code matches on `Effect` only. If the SCP has multiple Deny statements, the code will always modify the first one, which may not be the intended `BlockNewServices` statement.

**Fix**: Update `update_scp_with_services()` and `generate_scp_preview()` to match on `Sid` when `SCP_SID` is set:
```python
SCP_SID = os.environ.get('SCP_SID', 'BlockNewServices')
# In the loop:
if statement.get('Sid') == SCP_SID:
    deny_statement = statement
    break
```

---

## 4. Baseline Integrity System

### Strengths
- **SHA256 Checksums**: `calculate_baseline_checksum()` produces a deterministic hash over a sorted JSON representation of all tracked service names.
- **Immutable S3 Snapshots**: Baseline snapshots are written to an S3 bucket with GOVERNANCE-mode object lock (90-day retention), server-side encryption, and public access blocked.
- **Tamper Alert Path**: `verify_baseline_integrity()` compares the stored checksum against a live recalculation and sends both email and SNS alerts on mismatch.
- **Race Condition Prevention on Init**: `initialize_baseline()` uses a DynamoDB conditional write (`attribute_not_exists`) to prevent duplicate initialization.

### Baseline Checksum Update (Recent Addition)

The `update_baseline_checksum()` function was added to recalculate and persist the baseline checksum immediately after new services are stored in DynamoDB. This resolves a correctness issue where a successful service detection run would leave the stored checksum out of sync with the actual table contents, causing the next run to flag a false integrity violation.

**Security assessment**: The fix is correct and necessary. The checksum update is performed synchronously in the same Lambda invocation as the service write, before the function returns. This maintains the integrity property: the stored checksum always reflects the actual set of tracked services after a successful run.

**Residual concern**: If the Lambda times out or is killed between `store_new_services()` (line 1091) and `update_baseline_checksum()` (line 1092), the checksum will be stale and the next run will raise a false tamper alert. This is an edge case inherent to non-atomic DynamoDB multi-write operations. The impact is a false positive alert — not a security bypass. The S3 immutable snapshot can be used to distinguish a genuine tamper from a partial-write scenario.

### Residual Risks

#### Risk 1: Checksum Covers Service Names Only
**Severity**: LOW

The baseline checksum is computed only over `service_name` values. It does not cover the `is_baseline`, `first_seen`, or `last_updated` attributes. An attacker with DynamoDB write access who wanted to add a service silently would need to add a new item (detectable) or modify an existing service name (detectable). Modifying metadata fields is not detectable via the checksum, but metadata fields are not security-sensitive.

#### Risk 2: Baseline Marker Not Covered by Checksum
**Severity**: LOW

The `__baseline_initialized__` marker item is excluded from the checksum calculation via the `begins_with(service_name, :prefix)` filter. This is correct (the marker should not contribute to the service-set checksum), but it means an attacker could modify the stored checksum value in the marker item to match a corrupted service set. The S3 immutable snapshot provides the independent verification needed to detect this scenario.

---

## 5. GitHub Actions CI/CD Security

### Workflow Overview
Two workflows are in `.github/workflows/`:
- `claude.yml`: Triggers Claude Code on `@claude` mentions in issues and pull request comments/reviews.
- `claude-code-review.yml`: Automatically runs a Claude Code Review on every pull request open/update.

### Strengths
- **Minimal Permissions**: Both workflows declare only `contents: read`, `pull-requests: read`, `issues: read`, `id-token: write`, and `actions: read`. No `write` permissions to repository contents, secrets, or packages.
- **Secret via GitHub Secrets**: The Anthropic API key is passed as `${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}`, not hardcoded.
- **Pinned Checkout Action**: Both workflows use `actions/checkout@v4` (major-version pin).
- **No Elevated Shell Access by Default**: Neither workflow has `claude_args` overrides that would grant unrestricted Bash access.

### Risks

#### Risk 1: Third-Party Action — Unpinned to Digest
**Severity**: MEDIUM

Both workflows use `anthropics/claude-code-action@v1` (a mutable tag, not a commit SHA digest). If the action repository is compromised or the `v1` tag is moved to a malicious commit, it will execute with access to the `CLAUDE_CODE_OAUTH_TOKEN` secret.

**Mitigation**: Pin to a specific commit SHA:
```yaml
uses: anthropics/claude-code-action@<full-sha>  # e.g., @abc1234...
```
Review the action's release notes before updating the pin.

#### Risk 2: CLAUDE_CODE_OAUTH_TOKEN Scope
**Severity**: MEDIUM

The `CLAUDE_CODE_OAUTH_TOKEN` secret grants access to the Anthropic API on behalf of the account. If a pull request from a fork triggers `claude-code-review.yml`, the secret would be exposed to the fork's workflow context. GitHub does not pass secrets to fork pull requests by default for public repositories, but this should be confirmed.

**Mitigation**: Verify the repository is private, or add a trigger guard:
```yaml
if: github.event.pull_request.head.repo.full_name == github.repository
```
This prevents the review workflow from running on fork PRs where the secret context may behave differently.

#### Risk 3: Claude Code Agent — Code Execution Scope
**Severity**: MEDIUM

The `claude.yml` workflow (triggered by `@claude` mentions) runs the Claude Code agent with no `claude_args` restrictions. In principle this allows any commenter who can write `@claude` on an issue to instruct the agent to run arbitrary Bash commands within the GitHub Actions runner. The `contents: read` permission limits what the agent can commit back, but the runner itself has network access.

**Mitigation**: Restrict the `@claude` trigger to trusted collaborators, or add `allowed-tools` constraints:
```yaml
claude_args: '--allowed-tools Bash(gh pr *),Bash(gh issue *)'
```
Also consider adding a collaborator check in the `if:` condition:
```yaml
if: |
  github.event.comment.author_association == 'OWNER' ||
  github.event.comment.author_association == 'MEMBER' ||
  github.event.comment.author_association == 'COLLABORATOR'
```

#### Risk 4: Plugin Marketplace in Code Review Workflow
**Severity**: LOW

`claude-code-review.yml` uses `plugin_marketplaces: 'https://github.com/anthropics/claude-code.git'` and `plugins: 'code-review@claude-code-plugins'`. This fetches plugin code from an external GitHub repository at runtime. If that repository is compromised or the plugin reference is manipulated, the plugin code executes in the runner context.

**Mitigation**: Pin the plugin reference to a specific commit or release tag once the `claude-code-action` supports digest pinning for plugins.

#### Risk 5: Merge Conflict Markers in SECURITY.md
**Severity**: INFO (resolved in this update)

The previous version of SECURITY.md contained unresolved Git merge conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`). These have been removed in this revision. Ensure the source branch conflict is fully resolved before merging.

---

## 6. Network Security

### Strengths
- **HTTPS Enforced**: `requests.get(..., verify=True)` with explicit `SSLError` handling (prior recommendation implemented).
- **No Open Ports**: Lambda requires no inbound access.
- **No VPC**: Reduces attack surface for this use case.

### Residual Risks

#### Risk 1: Lambda Internet Access
**Severity**: LOW (accepted)

Lambda requires outbound internet access to reach `servicereference.eu-west-2.amazonaws.com`. This is expected and acceptable. If a VPC is added in future, configure a NAT gateway or VPC endpoint as appropriate.

#### Risk 2: DNS Spoofing
**Severity**: LOW

The `requests` library with `verify=True` validates the TLS certificate against the CA bundle, which provides protection against DNS spoofing (an attacker redirecting the domain to a different IP would not hold a valid certificate for `amazonaws.com`). No additional DNS validation is required.

---

## 7. Email & SES Security

### Strengths
- **HTML Escaping**: `generate_html_email()` applies `html.escape()` to service names in the HTML body (line 778). `send_approval_request_email()` also escapes the service name via `escape(service_name)` (line 940).
- **Text Email Safety**: Plain-text emails do not require HTML escaping. Service names have already been validated by `validate_service_names()` before reaching the email functions.
- **Structured SES Calls**: Emails use the `ses.send_email()` structured API (not raw SMTP), limiting header injection risk.

### Residual Risks

#### Risk 1: Approval Email — Service Name in Code Block
**Severity**: LOW

`send_approval_request_email()` renders the safe (escaped) service name inside a `<pre>` block for the Terraform snippet:
```python
<pre ...>approved_services = ["{safe_name}"]</pre>
```
The service name has been validated to match `^[a-z0-9\-]+$`, so it cannot contain quotes, backslashes, or injection characters. This is safe.

#### Risk 2: Email Recipients List Exposure
**Severity**: LOW (unchanged)

`EMAIL_RECIPIENTS` and `APPROVAL_RECIPIENTS` are stored in Lambda environment variables, visible in the AWS console. These are email addresses, not credentials. Acceptable given the operational model.

#### Risk 3: SES Sandbox Mode
**Severity**: OPERATIONAL

If the AWS account SES is in sandbox mode, emails can only be sent to verified addresses. Ensure all addresses in `email_recipients` and `approval_recipients` are SES-verified before deployment. The approval workflow sends per-service emails (`send_approval_request_email` is called once per unapproved service), which could generate significant SES volume if many services are detected at once. Monitor SES sending quotas.

---

## 8. Lambda Security

### Strengths
- **Top-level Exception Handler**: `lambda_handler()` wraps all logic in a `try/except Exception` and returns HTTP 500 with a sanitized message on unexpected errors.
- **Input Validation at Entry**: Service names from the external source are validated before any downstream action.
- **Print vs Logger Residue**: `store_new_services()` and `get_scp_policy()` still use `print()` instead of `logger`. This is cosmetic but means those messages bypass the structured logging configuration and may not appear in CloudWatch Insights queries that filter by log level.

### Residual Risks

#### Risk 1: MANAGE_SCP_POLICY NameError (see Section 3 — Issue 1)
**Severity**: HIGH

Runtime crash when new services are detected.

#### Risk 2: Partial-Write on Timeout
**Severity**: LOW

If Lambda times out between `store_new_services()` and `update_baseline_checksum()`, the table and checksum will be inconsistent, triggering a false tamper alert on the next run. S3 baseline snapshots allow distinguishing this from genuine tampering.

#### Risk 3: store_pending_scp_update — Uses Service Registry Table
**Severity**: INFO

`store_pending_scp_update()` writes a `__pending_scp_update__<timestamp>` item to `DYNAMODB_TABLE` (the service registry). Items prefixed with `__` are filtered out of `get_tracked_services()` correctly. However, `verify_baseline_integrity()` uses a DynamoDB filter expression that also excludes `__`-prefixed items, so pending SCP update records do not interfere with integrity checks. This is correct behaviour but worth documenting: the service registry table serves dual purpose.

#### Risk 4: No Dead Letter Queue
**Severity**: LOW (unchanged from prior review)

A Lambda DLQ has not been configured. Failed invocations (e.g., from EventBridge retries on a crash) are not captured. Consider:
```hcl
resource "aws_sqs_queue" "lambda_dlq" {
  name = "aws-service-monitor-dlq"
}
# reference in aws_lambda_function.service_monitor:
dead_letter_config {
  target_arn = aws_sqs_queue.lambda_dlq.arn
}
```

---

## 9. Audit & Logging

### Strengths
- **CloudWatch Logs**: All executions logged via `logger`.
- **CloudTrail**: All AWS API calls (DynamoDB, Organizations, SES, S3, SNS) are automatically logged.
- **Custom Metrics**: `publish_metrics()` pushes `NewServicesDetected`, `TotalTrackedServices`, and `BaselineIntegrityStatus` to the `AWS/ServiceMonitor` CloudWatch namespace.
- **Tamper Alert Chain**: Integrity violations trigger both email and SNS alerts, and publish a `BaselineIntegrityStatus=0` metric (usable to trigger a CloudWatch alarm).

### Residual Risks

#### Risk 1: print() Calls Bypass Structured Logger
**Severity**: LOW

`store_new_services()` (line 351, 354) and `get_scp_policy()` (lines 393, 402) use `print()`. These messages go to stdout and appear in CloudWatch Logs but are not associated with a log level, making them invisible to level-filtered Insights queries and potentially missing from structured log aggregation tools.

**Fix**: Replace `print()` with `logger.info()` / `logger.error()` calls.

#### Risk 2: Approval Audit Trail
**Severity**: MEDIUM

Pending approval records in DynamoDB track `detected_at` and `approval_requested_at` but have no field for who approved a service or when. Approval is performed out-of-band (Terraform PR merge), so the Git history is the de-facto audit trail. For environments requiring a formal audit log, add an `approved_by` and `approved_at` update to the DynamoDB record as part of the Terraform apply or a separate approval Lambda.

---

## 10. Operational Security

### Strengths
- **Approval Gate**: `REQUIRE_APPROVAL=true` (default) stores SCP changes as pending without applying them.
- **Notifications-Only Mode**: `manage_scp_policy = false` completely disables Organizations API calls.
- **CloudWatch Alarms**: `alarms.tf` provides metric-based alerting (baseline integrity metric usable for alarm trigger).

### Residual Risks

#### Risk 1: No Bulk-Detection Guard
**Severity**: MEDIUM

If the AWS service reference returns an unusually large number of new services (e.g., 50+ in one run due to a data anomaly or reference restructuring), the system will attempt to add all of them to the SCP, send individual approval request emails for each, and write all to DynamoDB. Add a per-run cap (see Section 3, Risk 4).

#### Risk 2: No Policy Drift Detection
**Severity**: LOW (unchanged)

The system does not detect if someone manually modifies the SCP outside of this Lambda. CloudTrail will log `UpdatePolicy` calls; consider a CloudWatch Metric Filter on CloudTrail logs for `organizations:UpdatePolicy` events not originating from the Lambda role.

---

## 11. Compliance & Governance

### Approval Workflow Security Properties

The service approval/allowlist workflow introduced in the current version has the following security properties:

1. **Separation of concerns**: New services are tracked in DynamoDB and notified via email before any SCP modification is considered.
2. **Allowlist is code-controlled**: Approved services are defined in `terraform.tfvars` (version-controlled), not editable via the console or DynamoDB directly.
3. **Approval is gate-controlled**: Services not in the approved list are blocked from SCP exclusion regardless of who requests it.
4. **Audit trail via Git**: Changes to `var.approved_services` require a Terraform PR, providing an auditable approval chain.

**Gap**: The `track_service_for_approval()` function writes a `pending` record to DynamoDB but there is no mechanism to transition that record to `approved` via code. The approval happens out-of-band (via `terraform.tfvars`). The DynamoDB pending records are informational only and may accumulate without cleanup.

---

## 12. Priority Recommendations

### Priority 1 (Critical — Fix Before Next Deployment)
- [ ] **Fix `MANAGE_SCP_POLICY` NameError**: Add `MANAGE_SCP_POLICY = os.environ.get('MANAGE_SCP_POLICY', 'true').lower() == 'true'` to `lambda/index.py` and the corresponding env var to `main.tf`.

### Priority 2 (High — Fix in Next Sprint)
- [ ] **Pin GitHub Actions to commit SHAs**: Replace `@v1` with a full commit digest for `anthropics/claude-code-action`.
- [ ] **Restrict `@claude` trigger to collaborators**: Add `author_association` check to `claude.yml` `if:` condition.
- [ ] **Fix Sid-based SCP statement matching**: Use `SCP_SID` env var in `update_scp_with_services()` and `generate_scp_preview()` instead of matching on `Effect` alone.
- [ ] **Replace `print()` with `logger` calls**: In `store_new_services()` and `get_scp_policy()`.

### Priority 3 (Important — Address Within Quarter)
- [ ] **Add fork PR guard to `claude-code-review.yml`**: Prevent the review workflow from running on fork PRs.
- [ ] **Add per-run service count cap**: Guard against bulk-detection anomalies from the service reference.
- [ ] **Configure Lambda DLQ**: Capture failed invocations for investigation.
- [ ] **Increase CloudWatch Logs retention**: From 14 days to 30–90 days for compliance.
- [ ] **Document approval audit trail**: Formally document Git history as the approval audit record, or implement a DynamoDB `approved_by`/`approved_at` update path.

### Priority 4 (Nice to Have)
- [ ] **Store email recipients in SSM Parameter Store**: If insider-threat model requires it.
- [ ] **Add Organizations API condition**: Restrict to specific SCP name.
- [ ] **Add SES FromAddress condition**: Restrict to configured sender email.
- [ ] **Add policy drift detection**: CloudWatch Metric Filter on CloudTrail for `organizations:UpdatePolicy`.
- [ ] **Implement DLQ alarm**: Alert when the DLQ receives messages.

---

## Security Checklist for Production Deployment

```
Identity & Access
- [ ] Review all IAM policies for least privilege
- [ ] Verify Organizations API condition restricts to specific policy name
- [ ] CloudWatch Logs policy scoped to specific log group (DONE)
- [ ] Enable CloudTrail logging (organization trail recommended)
- [ ] Audit role trust policies

Data Protection
- [ ] DynamoDB PITR enabled on both tables (DONE)
- [ ] Set CloudWatch Logs retention >= 30 days (currently 14)
- [ ] Encryption at rest via AWS-managed keys (DONE)
- [ ] Verify all email recipients in SES
- [ ] Confirm S3 baseline bucket object lock is active (DONE)

GitHub Actions
- [ ] Pin claude-code-action to commit SHA
- [ ] Add collaborator check to @claude trigger
- [ ] Add fork PR guard to code review workflow

Lambda Code
- [ ] Fix MANAGE_SCP_POLICY NameError (CRITICAL)
- [ ] Fix SCP Sid-based statement targeting
- [ ] Replace print() with logger in store_new_services() and get_scp_policy()
- [ ] Verify HTTPS certificate validation active (DONE)
- [ ] Review service name validation logic (DONE)

Service Control Policy
- [ ] Test SCP updates in staging/non-prod first
- [ ] Verify REQUIRE_APPROVAL=true for production
- [ ] Confirm manage_scp_policy setting matches intent
- [ ] Validate SCP Sid matches scp_sid variable

Approval Workflow
- [ ] Confirm approved_services list is correct in terraform.tfvars
- [ ] Verify APPROVAL_RECIPIENTS are SES-verified
- [ ] Document approval process and audit trail expectations
- [ ] Review pending records in approved-services DynamoDB table

Operational
- [ ] Set up CloudWatch alarm on BaselineIntegrityStatus metric
- [ ] Configure SNS topic subscriptions for alerts
- [ ] Test tamper detection end-to-end (see TESTING_GUIDE.md)
- [ ] Verify Lambda DLQ (not yet configured — see Priority 3)
- [ ] Document runbook for NameError recovery (if fix not yet deployed)
```

---

## Conclusion

The solution has matured significantly since the initial review. All Priority 1 items from the previous version are now implemented. The key remaining concerns are:

1. **`MANAGE_SCP_POLICY` NameError** — A code defect that will crash the Lambda on any run that detects new services. Must be fixed immediately.
2. **GitHub Actions action pinning** — Both workflows use mutable `@v1` tags for a third-party action that has access to an Anthropic API secret.
3. **SCP Sid targeting** — The `SCP_SID` variable is defined but not used in the statement selection logic, potentially causing the wrong statement to be modified in multi-statement policies.
4. **Approval audit trail** — Pending records in DynamoDB have no completion path; the approval audit trail relies entirely on Git history.

All other risks are low-severity or acknowledged AWS service limitations.
