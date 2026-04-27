# AWS New Services Monitor

A Terraform/OpenTofu project that automatically monitors AWS for new services and optionally manages a Service Control Policy (SCP) blacklist in your AWS Organization's management account.

**Two Operational Modes**:
- 🔒 **SCP Management Mode** (default): Automatically detects new services and updates your SCP policy
- 📢 **Notifications-Only Mode** (optional): Detects new services and sends alerts without modifying policies

## Features

- **Automated Monitoring**: Fetches the AWS service reference daily
- **New Service Detection**: Identifies only new services (ignores API changes)
- **State Tracking**: Maintains a registry of known services in DynamoDB
- **Email Notifications**: Sends human-readable emails when new services are detected
- **Optional SCP Management**: Automatically updates your blacklist SCP policy (configurable)
- **Flexible Deployment**: Choose between SCP management or notifications-only mode
- **Fully Infrastructure-as-Code**: Terraform/OpenTofu based deployment

## Architecture

```mermaid
graph TB
    subgraph "External"
        AWS["AWS Service Reference<br/>(servicereference.us-east-1.amazonaws.com)"]
    end
    
    subgraph "AWS Management Account"
        EB["EventBridge<br/>(Daily Schedule)<br/>cron(0 8 * * ? *)"]
        Lambda["Lambda Function<br/>(aws-service-monitor)"]
        CW["CloudWatch Logs<br/>(/aws/lambda/...)"]
        
        subgraph "Data"
            DB["DynamoDB<br/>(service-registry)<br/>State Tracking"]
        end
        
        subgraph "Integration"
            ORG["AWS Organizations<br/>(Service Control<br/>Policy Management)"]
            SES["Amazon SES<br/>(Email Notifications)"]
        end
    end
    
    subgraph "External Notification"
        EMAIL["Email Recipients"]
    end
    
    AWS -->|"Fetch services<br/>daily"| Lambda
    EB -->|"Trigger"| Lambda
    Lambda -->|"Read/Write<br/>tracked services"| DB
    Lambda -->|"Query & Update<br/>SCP Policy"| ORG
    Lambda -->|"Send formatted<br/>HTML+Text emails"| SES
    Lambda -->|"Write execution<br/>logs"| CW
    SES -->|"Email notification"| EMAIL
```

For detailed architecture documentation, see [ARCHITECTURE.md](./ARCHITECTURE.md)

## Prerequisites

- AWS Organizations enabled with management account access
- AWS credentials configured for the management account
- Terraform or OpenTofu installed (v1.0+)
- Email addresses verified in AWS SES (Simple Email Service) for your region
- **(Optional) SCP Management Mode Only**: An existing Service Control Policy named "blacklist" (or customize via `scp_name` variable) with a statement ID matching `scp_sid` (default: "BlockNewServices")

### Email Setup in SES

Before deploying, verify your email addresses in AWS SES:

```bash
# Using AWS CLI
aws ses verify-email-identity --email-address ops-team@example.com --region us-east-1
aws ses verify-email-identity --email-address aws-monitor@example.com --region us-east-1
```

Check your email for verification links and click them.

## Deployment

### 1. Configure Variables

Create a `terraform.tfvars` file from the example:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your specific values:

```hcl
aws_region = "us-east-1"
schedule_expression = "cron(0 8 * * ? *)"  # 8 AM UTC daily
email_recipients = ["ops-team@example.com"]
sender_email = "aws-monitor@example.com"

# Choose your mode:
# Option 1: SCP Management Mode (automatic policy updates)
manage_scp_policy = true
require_scp_approval = false  # true for approval-based, false for automatic
scp_name = "blacklist"
scp_sid = "BlockNewServices"  # Statement ID to update in the SCP

# Option 2: Notifications-Only Mode (no policy changes, just alerts)
manage_scp_policy = false
```

#### Operational Modes Explained

| Mode | Setting | Behavior | Use Case |
|------|---------|----------|----------|
| **SCP Management** | `manage_scp_policy = true` | Automatically detects new services and updates your SCP | Production environments with established policies |
| **Notifications-Only** | `manage_scp_policy = false` | Detects new services and sends alerts, but never modifies policies | Testing, audit, or manual SCP management |
| **Approval-Based** | `require_scp_approval = true` | Stores SCP changes for manual review before applying | Conservative environments requiring change control |
| **Automatic** | `require_scp_approval = false` | Applies SCP changes immediately | Fast-moving environments that trust the baseline |

### 2. Initialize and Plan

```bash
terraform init
terraform plan
```

### 3. Apply the Configuration

```bash
terraform apply
```

This will create:
- DynamoDB table for service registry
- Lambda function with necessary IAM roles
- EventBridge rule for daily scheduling
- CloudWatch log group for monitoring

## Usage

### Manual Trigger

To manually test the Lambda function:

```bash
aws lambda invoke \
  --function-name aws-service-monitor \
  --region us-east-1 \
  response.json

cat response.json
```

### View Logs

Monitor the Lambda execution logs:

```bash
aws logs tail /aws/lambda/aws-service-monitor --follow --region us-east-1
```

### Check Service Registry

View services stored in DynamoDB:

```bash
aws dynamodb scan \
  --table-name aws-service-monitor-registry \
  --region us-east-1
```

## Email Notification Format

When new services are detected, you'll receive formatted emails with:

- **Subject**: "AWS Service Monitor: N New Service(s) Detected"
- **Body** (HTML): Nicely formatted with:
  - List of new services detected
  - Timestamp of the scan
  - Actions taken (depends on mode - see below)
  - Next steps for review
- **Body** (Plain Text): Alternative text version for email clients that don't support HTML

### Email Content Based on Mode

**SCP Management Mode** (`manage_scp_policy = true`):
```
✅ SUCCESS: Service Control Policy Updated

New Services Detected: 3
- apigateway
- autoscaling
- dynamodb

Service Control Policy Status: Successfully Updated
- Policy Name: blacklist
- Action: Added new service actions to Deny statement
- Services in Policy: 450 total actions
```

**Notifications-Only Mode** (`manage_scp_policy = false`):
```
📢 NEW SERVICES DETECTED (Notifications-Only Mode)

New Services Detected: 3
- apigateway
- autoscaling
- dynamodb

Service Control Policy: Not Updated
- Mode: Notifications-only (SCP management disabled)
- Action: No policy changes made
- Next Steps: Manually add services to your SCP if desired
```

## Operational Modes

### Mode 1: SCP Management (Default)

**Configuration**:
```hcl
manage_scp_policy = true
```

**What Happens**:
- ✅ New services are detected
- ✅ DynamoDB registry is updated
- ✅ SCP policy is automatically updated with new service restrictions
- ✅ Email is sent confirming the SCP update

**Best For**:
- Production environments with established SCP policies
- Teams that want fully automated compliance enforcement
- Environments where new service restrictions should take effect immediately

**Requirements**:
- An existing SCP policy named "blacklist" (or custom name)
- Adequate IAM permissions for Organizations API

---

### Mode 2: Notifications-Only

**Configuration**:
```hcl
manage_scp_policy = false
```

**What Happens**:
- ✅ New services are detected
- ✅ DynamoDB registry is updated
- ✅ SCP policy is NOT modified
- ✅ Email is sent indicating "notifications-only" mode
- ℹ️ Manual action required to update SCP

**Best For**:
- Testing and validation before enabling SCP management
- Audit and compliance monitoring
- Teams that prefer manual SCP management
- Sandboxes where automatic policy changes are not desired

**Requirements**:
- No additional prerequisites
- No SCP policy required
- Can be deployed to any AWS account (not just management account)

---

## SCP Integration (Optional)

The Lambda function can optionally update your Service Control Policy when new services are detected. It specifically targets a statement by its ID (Sid) for safe and precise policy management.

### Enabling SCP Management

Set `manage_scp_policy = true` in `terraform.tfvars` to enable this feature. Also ensure your SCP has a statement with the Sid matching your `scp_sid` configuration (default: "BlockNewServices").

### How It Works (When Enabled)

1. Fetches the current policy from AWS Organizations
2. Locates the statement matching the configured `scp_sid`
3. Adds new service actions to that statement's Deny list
4. Updates the policy with the new service restrictions
5. Sends email confirmation of the SCP update

### Configuring the Statement ID

The Lambda will only update statements with a matching Sid. This allows you to have multiple statements in your SCP without unintended modifications.

**In terraform.tfvars**:
```hcl
scp_name = "blacklist"
scp_sid = "BlockNewServices"  # Must match the Sid in your SCP statement
```

### Creating the SCP (Optional)

**Note**: The SCP must exist before deployment if you plan to use SCP management. Create it with the appropriate Sid:

```bash
aws organizations create-policy \
  --content file://blacklist-policy.json \
  --description "Blacklist policy for restricted services" \
  --name blacklist \
  --type SERVICE_CONTROL_POLICY
```

Example `blacklist-policy.json` with proper Sid configuration:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowRootDeny",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "*",
      "Resource": "*"
    },
    {
      "Sid": "BlockNewServices",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "service-that-should-be-blocked:*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Important**: The Sid "BlockNewServices" (or whatever you set in `scp_sid`) must exist in your SCP statement. The Lambda will only update this specific statement.

### Multiple Statements

Your SCP can safely have multiple statements. Only the statement with the matching Sid will be updated:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PreventRootDisable",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "organizations:LeaveOrganization",
      "Resource": "*"
    },
    {
      "Sid": "BlockNewServices",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [],
      "Resource": "*"
    }
  ]
}
```

When new services are detected, only the "BlockNewServices" statement will be modified. The "PreventRootDisable" statement remains unchanged.

## Scheduling

The default schedule runs daily at 8 AM UTC. Modify the `schedule_expression` variable to change:

| Expression | Meaning |
|-----------|---------|
| `cron(0 8 * * ? *)` | Daily at 8 AM UTC |
| `cron(0 3 * * ? *)` | Daily at 3 AM UTC |
| `rate(12 hours)` | Every 12 hours |
| `rate(1 hour)` | Every hour |

[More cron expression examples](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cron-expressions.html)

## Monitoring

### CloudWatch Metrics

The Lambda function logs execution details. Monitor key metrics:

- Execution count
- Error rate
- Duration
- New services detected

### CloudWatch Alarms (Optional)

Create an alarm for Lambda errors:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name aws-service-monitor-errors \
  --alarm-description "Alert on Lambda errors" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --statistic Sum \
  --period 3600 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=FunctionName,Value=aws-service-monitor
```

## Costs

Estimated monthly costs (for 1 service monitor in us-east-1):

- **Lambda**: ~$0.20 (30 invocations × 300 seconds @ 1024 MB)
- **DynamoDB**: ~$1.00 (on-demand pricing)
- **CloudWatch Logs**: ~$0.50 (log retention)
- **SES**: ~$0.10 (30 emails)

**Total**: ~$2 per month

## Troubleshooting

### Lambda Execution Errors

Check logs:
```bash
aws logs tail /aws/lambda/aws-service-monitor --follow
```

### SCP Not Updating

Verify the SCP exists:
```bash
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
```

### Emails Not Sending

- Verify email addresses in SES:
  ```bash
  aws ses list-verified-email-addresses
  ```
- Check if account is in SES sandbox mode (verify all recipients)

### Services Not Being Tracked

Check DynamoDB table:
```bash
aws dynamodb scan --table-name aws-service-monitor-registry
```

## Updating the Deployment

### Add New Recipients

Update `terraform.tfvars`:
```hcl
email_recipients = ["ops-team@example.com", "new-recipient@example.com"]
```

Apply changes:
```bash
terraform apply
```

### Change Schedule

Update `schedule_expression` in `terraform.tfvars` and reapply.

### Modify Lambda Function

Edit `lambda/index.py`, then:
```bash
terraform apply
```

The Lambda code zip will be rebuilt automatically.

## Cleanup

To remove all resources:

```bash
terraform destroy
```

This will delete:
- Lambda function
- DynamoDB table (with all service history)
- IAM roles
- EventBridge rules
- CloudWatch log group

## Advanced Configuration

### Customize Email Template

Edit `generate_html_email()` and `generate_text_email()` functions in `lambda/index.py`.

### Filter Specific Services

Modify the service fetch logic in `fetch_aws_services()` to exclude certain services.

### Change SCP Strategy

Update `update_scp_with_services()` to implement different SCP modification logic.

## Security Best Practices

- **Least Privilege**: The Lambda role has minimal required permissions
- **No Hardcoded Credentials**: Uses IAM role assumed by Lambda
- **Encrypted Logs**: CloudWatch logs are encrypted by default
- **No Data Retention**: Service registry only stores service names
- **Email Security**: Verify all recipients in SES before sending

## Support & Issues

For issues or feature requests, check:
- CloudWatch logs: `/aws/lambda/aws-service-monitor`
- Lambda console for execution history
- DynamoDB table scan results