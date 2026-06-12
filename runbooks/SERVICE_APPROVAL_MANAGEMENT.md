# Runbook: Service Approval & Allowlist Management

**Severity**: MEDIUM  
**Response Time**: < 1 hour  
**Runbook Owner**: Security/Platform Team

---

## When to Use

- Approve a blacklisted service for use in the organization
- Move a service from "pending approval" to "approved" status
- Remove a service from the approved list
- Review pending approval requests
- Manage the service allowlist

---

## Overview

The Service Approval workflow allows you to:
- **Detect** new AWS services automatically via Lambda
- **Request approval** when a service is blacklisted
- **Approve** services manually to exclude them from the SCP deny list
- **Track** approval status for audit and compliance

### Approval States

```
New Service Detected
    ↓
Added to SCP Deny List (blocked)
    ↓
Approval Request Email Sent
    ↓
Service Status: "pending"
    ↓
Team Reviews & Approves
    ↓
Service Added to approved_services List
    ↓
Terraform Apply
    ↓
Service Status: "approved"
    ↓
Service Removed from SCP Deny List
```

---

## Approval Workflow

### Step 1: Receive Approval Request

When a new service is detected and your approval workflow is enabled, you'll receive an email:

```
From: aws-monitor@example.com
Subject: AWS Service Monitor: Approval Request for 'example-service'

SERVICE DETAILS:
  Service Name: example-service
  Detected At: 2026-04-29T08:15:33 UTC
  Status: Pending Approval

WHAT THIS MEANS:
This service is currently blocked by the SCP. You can approve it to move it to the allowlist.
```

### Step 2: Review the Service

Before approving, research the service:

```bash
# Check service documentation
aws service-name describe-service
# or visit: https://docs.aws.amazon.com/servicename/

# Check AWS service reference
curl -s https://servicereference.eu-west-2.amazonaws.com/ | jq '.services."service-name"'

# Verify no critical security concerns
# Consider impact on your organization's policies
```

### Step 3: Add to Approved Services

Update your terraform configuration:

```bash
# Edit terraform/terraform.tfvars
vim terraform/terraform.tfvars
```

Add the service to the approved list:

```hcl
approved_services = [
  "existing-service-1",
  "existing-service-2",
  "example-service"  # ← Add new approved service
]
```

**Important**: Only add services that have been reviewed and approved by your security team.

### Step 4: Apply Changes

Deploy the approval:

```bash
cd terraform

# Review changes
terraform plan

# Apply to exclude service from SCP deny list
terraform apply
```

Expected output:
```
aws_lambda_function.service_monitor: Environment variable 'APPROVED_SERVICES_LIST' updated

Apply complete! Resources modified: 1
```

### Step 5: Verify Deployment

Confirm the service is now approved:

```bash
# Check DynamoDB approval status (if using DB-backed approvals)
aws dynamodb query \
  --table-name aws-service-monitor-approved-services \
  --index-name approval-status-index \
  --key-condition-expression "approval_status = :status" \
  --expression-attribute-values '{":status":{"S":"approved"}}' \
  --region eu-west-2 | jq '.Items[] | select(.service_name.S == "example-service")'

# Or check terraform state (from terraform directory)
terraform state show aws_lambda_function.service_monitor | grep APPROVED_SERVICES_LIST
```

---

## Managing the Approval List

### View Current Approved Services

```bash
# From terraform configuration
grep -A 10 "approved_services = " terraform/terraform.tfvars

# Or from Lambda environment
aws lambda get-function \
  --function-name aws-service-monitor \
  --region eu-west-2 | jq '.Configuration.Environment.Variables.APPROVED_SERVICES_LIST' | jq .
```

### Add Multiple Services at Once

```hcl
approved_services = [
  "service-1",
  "service-2",
  "service-3",
  "service-4"
]
```

### Remove a Service from Approved List

If you need to re-block a previously approved service:

```hcl
approved_services = [
  # Removed: "old-service",
  "other-service"
]
```

Then run `terraform apply`.

### Batch Approval Process

For organizations with multiple pending approvals:

```bash
#!/bin/bash
# scripts/batch-approve-services.sh

SERVICES_TO_APPROVE=(
  "service-1"
  "service-2"
  "service-3"
)

# Add to terraform/terraform.tfvars
EXISTING_SERVICES=$(grep "approved_services = " terraform/terraform.tfvars | sed 's/approved_services = //')

for service in "${SERVICES_TO_APPROVE[@]}"; do
  echo "Approving: $service"
done

# Manual step: Edit terraform/terraform.tfvars with new services
# Then: terraform apply
```

---

## Monitoring Approval Status

### Check DynamoDB Approval Requests

```bash
# View all pending approvals
aws dynamodb query \
  --table-name aws-service-monitor-approved-services \
  --index-name approval-status-index \
  --key-condition-expression "approval_status = :status" \
  --expression-attribute-values '{":status":{"S":"pending"}}' \
  --region eu-west-2 | jq '.'

# View specific service status
aws dynamodb get-item \
  --table-name aws-service-monitor-approved-services \
  --key '{"service_name":{"S":"example-service"}}' \
  --region eu-west-2 | jq '.Item'
```

### CloudWatch Logs for Approval Actions

```bash
# View approval-related logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "approval" \
  --region eu-west-2 | jq '.events[] | .message'

# Example log entries:
# "Sent approval request email for service 'example-service'"
# "Tracked service 'example-service' for approval"
# "All new services are in approval list - no SCP update needed"
```

---

## Approval Configuration

### Enable/Disable Approval Workflow

In `terraform/terraform.tfvars`:

```hcl
# Enable approval workflow (sends approval request emails)
enable_service_approval_workflow = true

# Or disable for auto-block mode (no approval process)
enable_service_approval_workflow = false
```

### Configure Approval Recipients

```hcl
# Use default email recipients for approvals
# (if approval_recipients is empty)
email_recipients = ["ops-team@example.com"]

# Or specify separate approval recipients
approval_recipients = [
  "security-review@example.com",
  "infrastructure-team@example.com"
]
```

---

## Troubleshooting

### Service Not Being Excluded from SCP

**Problem**: Added service to approved_services but still appears in SCP deny list

**Solution**:
```bash
# 1. Verify terraform apply succeeded
terraform apply

# 2. Check Lambda environment variables updated
aws lambda get-function --function-name aws-service-monitor --region eu-west-2 | \
  jq '.Configuration.Environment.Variables.APPROVED_SERVICES_LIST'

# 3. Wait for next Lambda execution (or trigger manually)
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json | jq '.body'

# 4. Check SCP policy was updated
aws organizations describe-policy --policy-id p-xxxxx --content | jq '.Policy.Content | fromjson'
```

### Approval Email Not Received

**Problem**: Expected approval request email but didn't receive it

**Solution**:
```bash
# 1. Verify approval workflow is enabled
aws lambda get-function --function-name aws-service-monitor --region eu-west-2 | \
  jq '.Configuration.Environment.Variables.ENABLE_SERVICE_APPROVAL_WORKFLOW'

# 2. Check approval recipients configured
aws lambda get-function --function-name aws-service-monitor --region eu-west-2 | \
  jq '.Configuration.Environment.Variables.APPROVAL_RECIPIENTS' | jq .

# 3. Verify SES email verified
aws ses list-identities --region eu-west-2 | grep "your-email@example.com"

# 4. Check Lambda logs for send failures
aws logs tail /aws/lambda/aws-service-monitor --region eu-west-2 --filter-pattern "Failed to send approval" --follow

# 5. Check SES sending quota
aws ses get-account-sending-enabled --region eu-west-2
```

### Service Marked as Pending but Never Approved

**Problem**: Service is stuck in "pending" approval state

**Solution**:
```bash
# 1. Check when it was detected
aws dynamodb get-item \
  --table-name aws-service-monitor-approved-services \
  --key '{"service_name":{"S":"example-service"}}' \
  --region eu-west-2 | jq '.Item.detected_at'

# 2. Update status to approved manually (if needed)
aws dynamodb update-item \
  --table-name aws-service-monitor-approved-services \
  --key '{"service_name":{"S":"example-service"}}' \
  --update-expression "SET approval_status = :status, approved_at = :now" \
  --expression-attribute-values '{":status":{"S":"approved"},":now":{"S":"2026-04-29T08:15:33Z"}}' \
  --region eu-west-2

# 3. Add to approved_services list in terraform/terraform.tfvars
# 4. Run terraform apply
```

---

## Best Practices

✅ **DO:**
- Review all new services before approving
- Require security team sign-off for approvals
- Document approval decisions (comments in terraform/terraform.tfvars)
- Use separate approval_recipients for better control
- Audit approval history regularly
- Version control terraform/terraform.tfvars changes

❌ **DON'T:**
- Approve services without understanding their purpose
- Leave services in "pending" indefinitely
- Mix approved and pending services without tracking
- Remove approved services without impact analysis
- Disable approval workflow in production

---

## Approval Decision Tree

```
New Service Detected
    ├─ Is it AWS-managed? 
    │  ├─ YES → Check if needed in org
    │  │        ├─ YES → Approve
    │  │        └─ NO → Keep blocked
    │  └─ NO → Escalate to AWS
    │
    └─ Is it critical for operations?
       ├─ YES → Fast-track approval
       ├─ NO → Standard approval process
       └─ MAYBE → Require team consensus
```

---

## Quick Reference

| Task | Command |
|------|---------|
| View pending approvals | `aws dynamodb query --table-name aws-service-monitor-approved-services --index-name approval-status-index --key-condition-expression "approval_status = :status" --expression-attribute-values '{":status":{"S":"pending"}}' --region eu-west-2` |
| Add approved service | Edit `terraform/terraform.tfvars`, add to `approved_services` list, run `terraform apply` |
| Check approval status | `aws dynamodb get-item --table-name aws-service-monitor-approved-services --key '{"service_name":{"S":"service-name"}}' --region eu-west-2` |
| View recent approvals | `aws logs filter-log-events --log-group-name /aws/lambda/aws-service-monitor --filter-pattern "approval" --region eu-west-2` |
| Trigger manual scan | `aws lambda invoke --function-name aws-service-monitor --region eu-west-2 response.json` |

---

**Document Version**: 1.0  
**Last Updated**: 2026-04-29
