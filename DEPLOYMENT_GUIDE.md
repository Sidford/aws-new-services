# Deployment Guide

This guide walks through deploying the AWS Service Monitor to your AWS management account.

## Prerequisites Checklist

- [ ] Access to AWS management account with Organizations enabled
- [ ] AWS CLI configured with appropriate credentials
- [ ] Terraform or OpenTofu installed (v1.0+)
- [ ] Service Control Policy named "blacklist" already created
- [ ] Email addresses ready for SES verification

## Step 1: Verify Email Addresses in SES

Before deployment, all email addresses must be verified in AWS SES.

### Verify Sender Email

```bash
aws ses verify-email-identity \
  --email-address aws-monitor@example.com \
  --region us-east-1
```

Check your email inbox for verification link from AWS and click it.

### Verify Recipient Emails

```bash
aws ses verify-email-identity \
  --email-address ops-team@example.com \
  --region us-east-1

aws ses verify-email-identity \
  --email-address security-team@example.com \
  --region us-east-1
```

Verify all emails before proceeding.

### Check Verified Addresses

```bash
aws ses list-verified-email-addresses --region us-east-1
```

All addresses should appear in the list.

## Step 2: Verify Blacklist SCP Exists

Check if your "blacklist" SCP exists:

```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY --region us-east-1
```

Look for a policy named "blacklist" in the results.

### If SCP Doesn't Exist - Create It

```bash
aws organizations create-policy \
  --content file://example-blacklist-policy.json \
  --description "Service blacklist policy managed by monitoring" \
  --name blacklist \
  --type SERVICE_CONTROL_POLICY \
  --region us-east-1
```

Verify creation:

```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY --region us-east-1
```

## Step 3: Configure Terraform Variables

Create your configuration file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your details:

```hcl
# AWS region - must be us-east-1 for Organizations API
aws_region = "us-east-1"

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
- `aws_region`: Should be us-east-1 (Organizations API requirement)
- `scp_name`: Must match your existing SCP name exactly

## Step 4: Initialize Terraform

```bash
terraform init
```

This downloads AWS provider plugins and initializes the working directory.

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
  --region us-east-1
```

### Check DynamoDB Table

```bash
aws dynamodb describe-table \
  --table-name aws-service-monitor-registry \
  --region us-east-1
```

### Check EventBridge Rule

```bash
aws events describe-rule \
  --name aws-service-monitor-daily \
  --region us-east-1
```

## Step 8: Test the Deployment

### Manual Lambda Invocation

```bash
aws lambda invoke \
  --function-name aws-service-monitor \
  --region us-east-1 \
  response.json

cat response.json
```

Expected output (if no new services):
```json
{"statusCode": 200, "body": "\"No new services detected\""}
```

### Check CloudWatch Logs

```bash
aws logs tail /aws/lambda/aws-service-monitor \
  --region us-east-1 \
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
  --region us-east-1 \
  --follow

# Or check recent logs
aws logs tail /aws/lambda/aws-service-monitor \
  --region us-east-1 \
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
  --region us-east-1
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
   aws dynamodb list-tables --region us-east-1
   ```

2. Scan the table:
   ```bash
   aws dynamodb scan \
     --table-name aws-service-monitor-registry \
     --region us-east-1
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
