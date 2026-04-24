# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS Service Monitor is a Terraform/OpenTofu infrastructure-as-code project that automatically detects new AWS services and manages a Service Control Policy (SCP) blacklist in an AWS Organization. The system runs daily via EventBridge, fetches AWS services from the service reference, detects new services, updates a DynamoDB registry, modifies the SCP, and sends email notifications to ops teams.

## Architecture

The system consists of:

- **EventBridge Rule**: Triggers daily at 8 AM UTC via cron schedule
- **Lambda Function** (`lambda/index.py`): Core orchestration logic that:
  - Fetches AWS services from the public service reference endpoint
  - Compares against tracked services in DynamoDB
  - Updates the SCP with newly detected services
  - Stores baseline snapshots in S3 (for integrity verification)
  - Sends formatted HTML/text email notifications
  - Publishes CloudWatch metrics and SNS alerts
- **DynamoDB Table** (`service-registry`): Tracks known services and maintains baseline state
- **S3 Bucket**: Stores immutable baseline snapshots for audit/integrity
- **SES**: Sends email notifications to configured recipients
- **AWS Organizations**: Updates the SCP policy with new service restrictions
- **CloudWatch**: Logs all executions and metrics

The Lambda function is designed with approval gates, baseline integrity checking, and tamper detection capabilities (see BASELINE_INITIALIZATION.md and WELL_ARCHITECTED_REVIEW.md for security details).

## Key Files & Their Roles

- **Terraform configuration**: `main.tf` (primary infrastructure), `providers.tf` (AWS provider), `variables.tf` (input variables), `outputs.tf` (outputs)
- **Monitoring**: `alarms.tf` (CloudWatch alarms), `dashboards.tf` (CloudWatch dashboards)
- **Lambda code**: `lambda/index.py` (handler), `lambda/requirements.txt` (Python dependencies: boto3, requests)
- **Examples**: `example-blacklist-policy.json`, `terraform.tfvars.example`
- **Documentation**: 
  - `ARCHITECTURE.md` — System design and data flow
  - `DEVELOPMENT.md` — Customization and testing guide
  - `DEPLOYMENT_GUIDE.md` — Step-by-step deployment
  - `SECURITY.md` — Security controls and threat model
  - `WELL_ARCHITECTED_REVIEW.md` — AWS Well-Architected Framework review
  - `runbooks/` — Operational procedures for incidents and maintenance

## Common Commands

### Terraform/Infrastructure

```bash
# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# Check plan (shows what will be created/changed)
terraform plan

# Deploy infrastructure
terraform apply

# Preview changes before applying
terraform plan -out=tfplan

# Destroy all resources
terraform destroy
```

### Lambda Development & Testing

```bash
# Set up local development environment
python3 -m venv venv
source venv/bin/activate
pip install -r lambda/requirements.txt
pip install boto3 moto pytest  # Add test dependencies

# Run unit tests (if test file exists)
pytest lambda/test_index.py -v

# Local Lambda simulation (requires AWS SAM)
sam local invoke ServiceMonitorFunction --event event.json

# Format Python code
black lambda/index.py

# Lint Python code
pylint lambda/index.py
flake8 lambda/index.py

# Type check
mypy lambda/index.py
```

### AWS Operations

```bash
# Manually invoke Lambda function (replace region with your deployment region)
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json

# View Lambda logs in real-time (tail with --follow or --since 5m for recent logs)
aws logs tail /aws/lambda/aws-service-monitor --region eu-west-2 --follow

# Check DynamoDB registry contents (includes baseline marker and tracked services)
aws dynamodb scan --table-name aws-service-monitor-registry --region eu-west-2

# Verify SCP policy (if SCP management is enabled)
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
aws organizations describe-policy --policy-id <policy-id>

# Verify email addresses are registered in SES
aws ses list-identities --region eu-west-2

# Re-verify an email address in SES (required before it can receive notifications)
aws ses verify-email-identity --email-address user@example.com --region eu-west-2
```

## Development Workflow

1. **Make changes**: Edit Terraform files (`.tf`) or Lambda code (`lambda/index.py`)
2. **Validate**: Run `terraform validate` and test Lambda locally with pytest
3. **Plan**: Run `terraform plan` to see infrastructure changes
4. **Review**: Check the plan output carefully (especially when `manage_scp_policy = true`)
5. **Deploy**: Run `terraform apply` - Terraform automatically:
   - Runs `build_lambda.sh` to create `lambda.zip`
   - Archives the updated code
   - Uploads to Lambda via CloudFormation
6. **Test**: Invoke Lambda manually and check CloudWatch logs and DynamoDB

**Lambda Build Process:**
- `build_lambda.sh` is triggered automatically by Terraform when `lambda/index.py` or `lambda/requirements.txt` changes
- Creates a zip file with proper Lambda handler structure
- Handles dependency installation (boto3 is pre-installed in Lambda runtime)
- Do NOT manually commit `lambda.zip` or build artifacts to git

## Important Configuration Variables

These must be set in `terraform.tfvars` before deployment:

- `aws_region`: AWS region for deployment (typically `us-east-1`)
- `schedule_expression`: EventBridge cron expression (default: `cron(0 8 * * ? *)` for daily 8 AM UTC)
- `scp_name`: Name of existing SCP to manage (default: `blacklist`)
- `email_recipients`: List of email addresses to notify (must be verified in SES before deployment)
- `sender_email`: Email address sending notifications (must be verified in SES before deployment)
- `require_approval`: Whether to require approval before SCP changes (default: `true`)
- `manage_scp_policy`: Enable/disable automatic SCP policy management (default: `true`). Set to `false` for **notifications-only mode** (detects new services, sends emails, but does NOT modify SCP policies)
- `baseline_snapshot_bucket`: S3 bucket for baseline snapshots (optional, for integrity checking)

**Note on Notifications-Only Mode:** When `manage_scp_policy = false`:
- Email templates automatically exclude SCP-related sections
- No Organizations API calls are made
- All monitoring, detection, and notification features remain active

## Sensitive Configuration

- **terraform.tfvars**: Do NOT commit (listed in .gitignore). Use `terraform.tfvars.example` as template
- **AWS Credentials**: Must be configured via AWS CLI or environment variables before terraform/Lambda deployment
- **Email Verification**: Sender and recipient emails must be verified in SES before deployment

## Infrastructure Cleanup

When running `terraform destroy`, note:
- The S3 baseline bucket has object lock with GOVERNANCE retention enabled for security
- Terraform cannot delete S3 buckets with retained objects - manual cleanup is required:
  ```bash
  BUCKET="service-monitor-baseline-ACCOUNT-ID-REGION"
  # List and delete all versions with bypass flag
  aws s3api list-object-versions --bucket "$BUCKET" | jq '.Versions[].VersionId' | \
    xargs -I {} aws s3api delete-object --bucket "$BUCKET" --key <key> --version-id {} \
      --bypass-governance-retention
  # Then retry terraform destroy
  ```
- Build artifacts (`lambda.zip`, `lambda_build/`) are safe to delete locally

## Testing Strategy

The DEVELOPMENT.md file provides detailed guidance on:
- Unit testing Lambda functions with moto (AWS mocking)
- Integration testing against real AWS (deploy to staging account first)
- Local DynamoDB testing with docker
- CloudWatch Logs Insights queries for debugging

Always test in a non-production AWS account before deploying to the management account.

**Manual Testing New Service Detection:**
To test the new service detection and email notification flow:
1. Remove a service from DynamoDB: `aws dynamodb delete-item --table-name aws-service-monitor-registry --key '{"service_name":{"S":"SERVICE_NAME"}}'`
2. Update the baseline checksum to match the reduced service count (recalculate SHA256 of sorted service list)
3. Invoke Lambda and verify it detects the service as "new" in the response
4. Check CloudWatch logs for "Sent email notification" confirmation
5. Restore the service and original baseline checksum to clean up

**Email Template Behavior:**
- When `manage_scp_policy = true`: Email includes SCP status, actions, and next steps
- When `manage_scp_policy = false`: Email omits all SCP-related sections for clarity

## Security & Operational Notes

- **Approval Gates**: The Lambda function can require approval before applying SCP changes (see REQUIRE_APPROVAL environment variable)
- **Baseline Integrity**: System maintains checksums and snapshots in S3 to detect tampering
- **Least Privilege**: Lambda role has minimal IAM permissions (see main.tf for exact permissions)
- **Threat Model**: Documented in `threat-model/THREAT_MODEL.md` with implementation tracking in `T004_IMPLEMENTATION.md`
- **Operational Runbooks**: See `runbooks/` directory for incident response procedures (e.g., SCP rollback, DynamoDB recovery, Lambda timeout recovery)

## Performance Considerations

- Lambda timeout: Usually sufficient for daily runs, but see `runbooks/LAMBDA_TIMEOUT_RECOVERY.md` for tuning
- DynamoDB: Uses on-demand billing by default (adjust in main.tf if needed for high-volume scenarios)
- Email delivery: SES has sending limits if account is in sandbox mode (verify all recipients)
- Service reference fetch: Uses 30-second timeout with SSL verification enabled

## Common Customizations

All documented in DEVELOPMENT.md with code examples:

1. **Add Slack notifications**: Integrate webhook URL in Lambda environment variables
2. **Add SNS alerts**: Send to SNS topic for additional notification channels
3. **Filter services**: Exclude certain services from monitoring
4. **Group services**: Categorize services in email notifications
5. **Change email template**: Customize HTML/text email generation functions
