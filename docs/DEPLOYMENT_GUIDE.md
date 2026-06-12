# Deployment Guide

This guide walks through deploying the AWS Service Monitor to your AWS management account.

## Prerequisites Checklist

- [ ] Access to AWS management account with Organizations enabled
- [ ] AWS CLI configured with appropriate credentials
- [ ] Terraform or OpenTofu installed (v1.0+)
- [ ] Service Control Policy named "blacklist" already created
- [ ] Email addresses ready for SES verification

## Step 0: Bootstrap Terraform State Backend (One-Time Setup)

**This step only needs to be done once.** It creates the S3 bucket and DynamoDB table that will store your Terraform state remotely.

### Initialize Bootstrap Infrastructure

Navigate to the bootstrap directory and deploy the backend infrastructure:

```bash
cd bootstrap
terraform init
```

This initializes Terraform with local state (safe, since this is temporary).

### Deploy Backend Resources

```bash
AWS_PROFILE=sidford-mgmt terraform apply
```

When prompted, review the resources being created:
- S3 bucket for Terraform state (with encryption, versioning, and object lock)
- DynamoDB table for state locking

Type `yes` to confirm.

### Note the Outputs

After successful deployment, note the outputs:
```
Outputs:

tfstate_bucket = "aws-service-monitor-tfstate-556717286844-eu-west-2"
tfstate_dynamodb_table = "aws-service-monitor-tfstate-lock"
```

These values are already configured in the root `backend.tf`.

### Return to Root Directory

```bash
cd ..
```

You're now ready to deploy the main infrastructure.

## Step 1: Verify Email Addresses in SES

Before deployment, all email addresses must be verified in AWS SES.

### Verify Sender Email

```bash
aws ses verify-email-identity \
  --email-address aws-monitor@example.com \
  --region eu-west-2
```

Check your email inbox for verification link from AWS and click it.

### Verify Recipient Emails

```bash
aws ses verify-email-identity \
  --email-address ops-team@example.com \
  --region eu-west-2

aws ses verify-email-identity \
  --email-address security-team@example.com \
  --region eu-west-2
```

Verify all emails before proceeding.

### Check Verified Addresses

```bash
aws ses list-verified-email-addresses --region eu-west-2
```

All addresses should appear in the list.

## Step 2: Verify Blacklist SCP Exists

Check if your "blacklist" SCP exists:

```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY --region eu-west-2
```

Look for a policy named "blacklist" in the results.

### If SCP Doesn't Exist - Create It

```bash
aws organizations create-policy \
  --content file://example-blacklist-policy.json \
  --description "Service blacklist policy managed by monitoring" \
  --name blacklist \
  --type SERVICE_CONTROL_POLICY \
  --region eu-west-2
```

Verify creation:

```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY --region eu-west-2
```

## Step 3: Configure Terraform Variables

Create your configuration file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your details:

```hcl
# AWS region - must be eu-west-2 for Organizations API
aws_region = "eu-west-2"

# Schedule: daily at 8 AM UTC (adjust as needed)
schedule_expression = "cron(0 8 * * ? *)"

# Name of your blacklist SCP
scp_name = "blacklist"

# Email recipients for notifications
email_recipients = [
  "ops-team@example.com",
  "security-team@example.com"
]

# Sender email (must be verified in SES)
sender_email = "aws-monitor@example.com"

# Optional: Custom tags
tags = {
  Project     = "AWS-Service-Monitor"
  Environment = "Management"
  ManagedBy   = "Terraform"
  CostCenter  = "Security"
  Owner       = "Platform-Team"
}
```

**Important Notes:**
- `email_recipients`: All addresses must be SES-verified
- `sender_email`: Must be SES-verified
- `aws_region`: Should be eu-west-2 (Organizations API requirement)
- `scp_name`: Must match your existing SCP name exactly

## Step 4: Initialize Terraform with S3 Backend

From the root directory (not bootstrap):

```bash
terraform init
```

This downloads AWS provider plugins and initializes the working directory. When prompted about migrating state to S3 backend, confirm by typing `yes`. Your state will now be stored remotely in the S3 bucket created in Step 0.

## Step 5: Review the Plan

```bash
terraform plan
```

Review the output to see what resources will be created:

- DynamoDB table: `aws-service-monitor-registry`
- Lambda function: `aws-service-monitor`
- IAM roles and policies
- EventBridge rule: `aws-service-monitor-daily`
- CloudWatch log group: `/aws/lambda/aws-service-monitor`

Confirm all resources match your expectations.

## Step 6: Deploy

```bash
terraform apply
```

When prompted, type `yes` to confirm the deployment.

Expected output:
```
aws_dynamodb_table.service_registry: Creating...
aws_iam_role.lambda_role: Creating...
...
Apply complete! Resources: X added, 0 changed, 0 destroyed.
```

## Step 7: Verify Deployment

### Check Lambda Function

```bash
aws lambda get-function \
  --function-name aws-service-monitor \
  --region eu-west-2
```

### Check DynamoDB Table

```bash
aws dynamodb describe-table \
  --table-name aws-service-monitor-registry \
  --region eu-west-2
```

### Check EventBridge Rule

```bash
aws events describe-rule \
  --name aws-service-monitor-daily \
  --region eu-west-2
```

## Step 8: Test the Deployment

### Manual Lambda Invocation (First Run - Baseline Initialization)

On the first run, the Lambda function will initialize a baseline with all current services:

```bash
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json

cat response.json
```

Expected output (first run):
```json
{
  "statusCode": 200,
  "body": "{
    \"message\": \"Baseline established\",
    \"baseline_services\": 234,
    \"status\": \"baseline_initialized\",
    \"note\": \"No actions taken on first run. Monitoring will begin on next execution.\",
    \"scan_time\": \"2026-04-24T12:00:00.000000\"
  }"
}
```

**Key Points:**
- ✅ Baseline is stored in DynamoDB
- ✅ No emails sent
- ✅ No SCP changes made
- ✅ Ready for production use

### Wait for Second Run (or Trigger Manually)

On the next execution (after 24 hours or manual trigger):

```bash
# Manual trigger for testing
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json

cat response.json
```

Expected output (subsequent runs):
```json
{
  "statusCode": 200,
  "body": "{
    \"message\": \"No new services detected\",
    \"scan_time\": \"2026-04-24T13:00:00.000000\"
  }"
}
```

Or if new services exist:
```json
{
  "statusCode": 200,
  "body": "{
    \"message\": \"Processed 5 new services\",
    \"new_services\": [\"service1\", \"service2\", ...],
    \"scp_status\": \"pending_approval\",
    \"scan_time\": \"2026-04-24T13:00:00.000000\"
  }"
}
```

### Check CloudWatch Logs

```bash
aws logs tail /aws/lambda/aws-service-monitor \
  --region eu-west-2 \
  --follow
```

You should see log entries showing:
- Service count from AWS reference
- Tracked services count
- Number of new services
- Actions taken

### Verify Email Sending (Optional)

To test email functionality, check if the Lambda executed successfully and review logs. Once emails are sent, you'll receive them at configured recipient addresses.

## Step 9: Monitor Initial Run

The Lambda will automatically run according to the schedule. Monitor the first run:

```bash
# Watch logs in real-time
aws logs tail /aws/lambda/aws-service-monitor \
  --region eu-west-2 \
  --follow

# Or check recent logs
aws logs tail /aws/lambda/aws-service-monitor \
  --region eu-west-2 \
  --since 1h \
  --max-items 100
```

## Troubleshooting

### Lambda Execution Fails

Check detailed error logs:

```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "Error" \
  --region eu-west-2
```

Common issues:
- **SCP not found**: Verify SCP name matches exactly (case-sensitive)
- **Email verification**: Confirm all emails are verified in SES
- **IAM permissions**: Check the Lambda role has required permissions

### No Email Received

1. Check Lambda logs for email sending errors
2. Verify recipient email is SES-verified
3. Check spam/junk folders
4. Verify SES sandbox status (if in sandbox, only verified addresses can receive)

### Services Not Being Tracked

1. Check DynamoDB table exists:
   ```bash
   aws dynamodb list-tables --region eu-west-2
   ```

2. Scan the table:
   ```bash
   aws dynamodb scan \
     --table-name aws-service-monitor-registry \
     --region eu-west-2
   ```

3. Check Lambda logs for fetch errors

## Next Steps

After successful deployment:

1. **Review Email Format**: Receive first email and verify readability
2. **Adjust Schedule**: Modify `schedule_expression` if needed
3. **Add More Recipients**: Update `email_recipients` and run `terraform apply`
4. **Monitor Costs**: Check CloudWatch for Lambda execution metrics
5. **Review SCP**: Verify services are being added to the blacklist SCP

## Rollback

To remove all resources if needed:

```bash
terraform destroy
```

**Warning**: This will delete:
- Lambda function
- DynamoDB table (including all historical service data)
- IAM roles
- EventBridge rules
- CloudWatch logs

The SCP itself is NOT deleted; you'll need to manage it separately if desired.

## Support

For issues:

1. Check CloudWatch logs: `/aws/lambda/aws-service-monitor`
2. Review Lambda execution history in AWS console
3. Verify IAM permissions on Lambda role
4. Check SES email verification status
5. Ensure Organizations API is accessible from management account
