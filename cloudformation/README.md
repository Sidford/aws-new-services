# AWS Service Monitor — CloudFormation Distribution

A pure-CloudFormation alternative to the Terraform deployment.
All deployed AWS resources and IAM permissions are identical; only the tooling changes.

The Lambda function code is **embedded directly in `template.yaml`** using CloudFormation's
`ZipFile` property — no separate build step, no S3 bucket for Lambda code, no zip file to manage.

## Files

| File | Purpose |
|------|---------|
| `template.yaml` | Single stack — all resources + embedded Lambda code |
| `deploy.sh` | Helper script: uploads the template to S3 and deploys the stack |
| `parameters.example.json` | Annotated parameter reference |

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS CLI v2 | Configured with credentials for your management account |
| SES email verification | Sender **and** each recipient must be verified in SES before the Lambda can send mail |
| AWS Organizations | The account must be the management account if `ManageScpPolicy=true` |

> **Why S3 for the template?**  CloudFormation's `--template-body` direct-upload limit is 51 KB.
> `template.yaml` is ~105 KB (Lambda code is embedded), so the script uploads it to S3 and
> deploys via `--template-url`.  A single small S3 bucket is created automatically.

---

## Quick start — deploy.sh

The script handles the full workflow in one command:

```bash
chmod +x cloudformation/deploy.sh

./cloudformation/deploy.sh \
  --region  eu-west-2 \
  --email   '["ops@example.com","security@example.com"]' \
  --sender  notifications@example.com
```

The script will:
1. Create/reuse an S3 bucket (`aws-service-monitor-deploy-<account>-<region>`).
2. Upload `template.yaml` to that bucket.
3. Validate the template via CloudFormation.
4. Show a change-set diff and prompt for approval before deploying.

### All options

```text
--stack-name NAME       Stack name                  (default: aws-service-monitor)
--region REGION         Deployment region           (default: eu-west-2)
--deploy-bucket BUCKET  S3 bucket for the template  (auto-created if omitted)
--email EMAILS          JSON array of recipients    (e.g. '["ops@example.com"]')
--sender EMAIL          SES verified sender address
--no-approve            Skip change-set approval prompt (CI mode)
```

Environment variables `STACK_NAME`, `DEPLOY_REGION`, `DEPLOY_BUCKET`,
`EMAIL_RECIPIENTS`, and `SENDER_EMAIL` are honoured as defaults.

---

## Manual deployment

If you prefer to drive the AWS CLI directly:

### 1 — Upload the template to S3

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-west-2
BUCKET="aws-service-monitor-deploy-${ACCOUNT}-${REGION}"

# Create the bucket (skip if it already exists)
aws s3 mb "s3://${BUCKET}" --region "$REGION"

# Upload
aws s3 cp cloudformation/template.yaml \
  "s3://${BUCKET}/aws-service-monitor/template.yaml" \
  --region "$REGION"
```

### 2 — Deploy the stack

```bash
aws cloudformation deploy \
  --stack-name aws-service-monitor \
  --template-url "https://s3.amazonaws.com/${BUCKET}/aws-service-monitor/template.yaml" \
  --region eu-west-2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EmailRecipients='["ops@example.com"]' \
    SenderEmail=notifications@example.com \
    ManageScpPolicy=true \
    ScpName=blacklist \
    ScpSid=BlockNewServices \
    RequireScpApproval=true \
    OrganizationId=o-xxxxxxxxxxxx
```

Or use a parameters file:

```bash
cp cloudformation/parameters.example.json cloudformation/parameters.json
# edit parameters.json ...

aws cloudformation deploy \
  --stack-name aws-service-monitor \
  --template-url "https://s3.amazonaws.com/${BUCKET}/aws-service-monitor/template.yaml" \
  --region eu-west-2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides file://cloudformation/parameters.json
```

---

## Parameter reference

### Required

| Parameter | Description |
|-----------|-------------|
| `EmailRecipients` | JSON array, e.g. `["ops@example.com","sec@example.com"]` |
| `SenderEmail` | SES-verified sender address |

### Important: JSON array format

Several parameters expect a **JSON array string**, not a plain comma-separated list.
This is because the Lambda reads them with `json.loads()`.

```
✅  ["ops@example.com","sec@example.com"]
✅  ["ec2","s3","lambda"]
❌  ops@example.com,sec@example.com   ← plain CSV causes a runtime error
```

### Optional (all have sensible defaults)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ManageScpPolicy` | `true` | `false` = notifications only, no SCP changes |
| `ScpName` | `blacklist` | Name of the SCP to manage |
| `ScpSid` | `BlockNewServices` | Statement ID updated in the SCP |
| `RequireScpApproval` | `true` | Approval gate — Lambda notifies but does not apply changes |
| `OrganizationId` | *(empty)* | AWS Org ID (`o-xxx`) for least-privilege IAM scoping |
| `EnableServiceApprovalWorkflow` | `true` | Approval workflow for moving services to the allow-list |
| `ApprovedServices` | `[]` | JSON array of services excluded from the deny-list |
| `ApprovalRecipients` | `[]` | JSON array; falls back to `EmailRecipients` when `[]` |
| `ScheduleExpression` | `cron(0 8 * * ? *)` | EventBridge schedule (8 AM UTC daily) |
| `EnableCloudWatchDashboard` | `true` | Create a CloudWatch dashboard |

---

## Post-deployment steps

### Verify email addresses (SES)

Every address in `EmailRecipients` and `SenderEmail` must be SES-verified:

```bash
aws ses verify-email-identity --email-address notifications@example.com --region eu-west-2
aws ses verify-email-identity --email-address ops@example.com           --region eu-west-2
```

Each address receives a verification email — click the link.

### Confirm SNS subscriptions

Each email in `EmailRecipients` also receives an SNS subscription confirmation.
The Lambda will not deliver alerts until each subscription is confirmed.

### Test the Lambda

```bash
# Manual invocation
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json

# Tail logs in real time
aws logs tail /aws/lambda/aws-service-monitor --region eu-west-2 --follow
```

---

## Updating the stack

Re-run `deploy.sh` (or upload the template and run `aws cloudformation deploy`) after any change
to `template.yaml`.  The script shows a change-set diff before applying.

---

## Destroying the stack

```bash
# ⚠ The S3 baseline bucket uses Object Lock with GOVERNANCE retention.
# CloudFormation cannot delete it automatically — remove objects first:

BUCKET="service-monitor-baseline-$(aws sts get-caller-identity --query Account --output text)-eu-west-2"

aws s3api list-object-versions --bucket "$BUCKET" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('Versions', []):
    print(v['Key'], v['VersionId'])
" | while read key version; do
    aws s3api delete-object --bucket "$BUCKET" \
      --key "$key" --version-id "$version" \
      --bypass-governance-retention
  done

# Then delete the stack
aws cloudformation delete-stack --stack-name aws-service-monitor --region eu-west-2
```

---

## Differences from the Terraform version

| Aspect | Terraform | CloudFormation |
|--------|-----------|----------------|
| State management | S3 backend + DynamoDB lock table | Managed by CloudFormation service |
| Bootstrap step | `terraform/bootstrap/` (one-time) | None required |
| Lambda code | Packaged as `lambda.zip`, stored in S3 | Embedded in `template.yaml` (`ZipFile`) |
| SNS subscriptions | `count` over a list variable | Inline custom-resource Lambda |
| Module structure | 7 modules in `terraform/modules/` | Single `template.yaml` |

---

## Troubleshooting

**`ROLLBACK_COMPLETE` on first deploy**
Check the Events tab in the CloudFormation console for the failing resource.
Common causes: IAM name collision (role/policy already exists), or S3 bucket name already taken.

**Lambda error: `json.loads` on env var**
A list parameter was passed as plain CSV instead of a JSON array.
Check `EmailRecipients`, `ApprovedServices`, `ApprovalRecipients`.

**Emails not arriving**
Confirm SES verification and SNS subscription confirmation for every address.
In SES sandbox mode all recipient addresses must also be individually verified.

**Change-set status `FAILED` with "No updates are to be performed"**
The stack is already up to date — no changes needed.

**Template validation error: "Template format error: Template size ... exceeds limit"**
Make sure you are using `--template-url` (pointing to the S3-hosted copy), not `--template-body`.
The `deploy.sh` script handles this automatically.
