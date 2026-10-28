<div align="center">

# ☁️ CloudFormation Deployment

### Two-stack · no extra tooling · `aws cloudformation deploy` only

<br/>

[![Infrastructure Stack](https://img.shields.io/badge/stack_1-infrastructure-FF9900?style=for-the-badge&logo=amazon-web-services&logoColor=white)](#stack-1--infrastructure)
[![Application Stack](https://img.shields.io/badge/stack_2-application-3498DB?style=for-the-badge&logo=aws-lambda&logoColor=white)](#stack-2--application)

<br/>

[![No S3 Upload](https://img.shields.io/badge/no_S3_upload_needed-deploy_direct-2ECC71?style=flat-square)](README.md)
[![No Build Step](https://img.shields.io/badge/no_build_step-Lambda_code_embedded-2ECC71?style=flat-square)](README.md)
[![CAPABILITY_NAMED_IAM](https://img.shields.io/badge/requires-CAPABILITY__NAMED__IAM-E74C3C?style=flat-square)](README.md)

</div>

---

## Why two stacks?

| | Single stack | Two stacks |
|--|-------------|------------|
| Update Lambda code | Touches IAM, KMS, DynamoDB | **Application stack only** |
| Change email recipients | Redeploy everything | **Infrastructure stack only** |
| Risk on update | High (stateful resources) | Low (compute is isolated) |
| Deploy time | Longer | Faster for app-only changes |

---

## Files

| File | Stack | Purpose |
|------|-------|---------|
| `infrastructure.yaml` | Stack 1 | IAM, KMS, DynamoDB, S3, SNS, log group |
| `infra-parameters.example.json` | Stack 1 | Parameter template — copy and edit |
| `application.yaml` | Stack 2 | Lambda, EventBridge, alarms, dashboard |
| `app-parameters.example.json` | Stack 2 | Parameter template — copy and edit |

> The Lambda code is **embedded directly** in `application.yaml` using CloudFormation's `ZipFile` property — no zip file, no separate build step, no S3 bucket for code.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS CLI v2 | Configured with credentials for your management account |
| SES verified emails | Sender **and** each recipient must be SES-verified before the Lambda can send mail |
| AWS Organizations | Required if `ManageScpPolicy=true` — account must be the management account |
| Existing SCP named `blacklist` | The policy the Lambda will update |

---

## Quick start

### 1 — Copy and edit the parameter files

```bash
cp cloudformation/infra-parameters.example.json  cloudformation/infra-parameters.json
cp cloudformation/app-parameters.example.json    cloudformation/app-parameters.json
```

Minimum edits in `infra-parameters.json`:

```json
{ "ParameterKey": "EmailRecipients", "ParameterValue": "[\"ops@example.com\"]" },
{ "ParameterKey": "SenderEmail",     "ParameterValue": "notifications@example.com" },
{ "ParameterKey": "OrganizationId",  "ParameterValue": "o-xxxxxxxxxxxx" }
```

`app-parameters.json` works out of the box with defaults — change `InfrastructureStackName` only if you renamed the infra stack.

---

### 2 — Deploy Stack 1: infrastructure

```bash
aws cloudformation deploy \
  --template-file cloudformation/infrastructure.yaml \
  --stack-name aws-service-monitor-infra \
  --parameter-overrides file://cloudformation/infra-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-2
```

**Creates**:
- 🔑 KMS CMK + alias (DynamoDB encryption, auto-rotating)
- 🔐 IAM execution role + permission boundary
- 💾 DynamoDB tables: `service-registry`, `approved-services`, `pending-regional`
- 📦 S3 baseline bucket (Object Lock GOVERNANCE, 90-day retention)
- 📢 SNS alerts topic + email subscriptions
- 📝 CloudWatch log group
- 🛡️ 8 scoped IAM policies attached to the role

> ⏱ First deploy takes ~3 minutes. Wait for `CREATE_COMPLETE` before deploying Stack 2.

---

### 3 — Deploy Stack 2: application

```bash
aws cloudformation deploy \
  --template-file cloudformation/application.yaml \
  --stack-name aws-service-monitor-app \
  --parameter-overrides file://cloudformation/app-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-2
```

> `application.yaml` is > 51 KB (Lambda code embedded). `aws cloudformation deploy --template-file` automatically uploads to an AWS-managed S3 staging bucket — **you don't need to do anything extra**.

**Creates**:
- ⚡ Lambda function (Python 3.11, 300 s timeout)
- 📅 EventBridge rule (daily at 08:00 UTC)
- 🚨 10 CloudWatch alarms (errors, timeouts, integrity, throttles, missed runs)
- 📊 CloudWatch dashboard

---

### 4 — Post-deployment checks

```bash
# Both stacks should show CREATE_COMPLETE
aws cloudformation describe-stacks \
  --stack-name aws-service-monitor-infra \
  --region eu-west-2 \
  --query 'Stacks[0].StackStatus'

aws cloudformation describe-stacks \
  --stack-name aws-service-monitor-app \
  --region eu-west-2 \
  --query 'Stacks[0].StackStatus'

# Trigger a test run
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json | jq '.'

# Tail logs
aws logs tail /aws/lambda/aws-service-monitor --region eu-west-2 --follow
```

**After deploy — confirm emails**:

1. Each address in `EmailRecipients` receives an **SNS subscription confirmation** — click the link or alerts won't be delivered.
2. Verify sender/recipient emails in SES if not already done:

```bash
aws ses verify-email-identity --email-address notifications@example.com --region eu-west-2
aws ses verify-email-identity --email-address ops@example.com           --region eu-west-2
```

---

## Stack 1 — Infrastructure

### Parameters

#### Required

| Parameter | Example | Description |
|-----------|---------|-------------|
| `EmailRecipients` | `["ops@example.com"]` | JSON array — notification recipients |
| `SenderEmail` | `notifications@example.com` | SES-verified sender |

#### Optional

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ApprovalRecipients` | `[]` | Approval-workflow recipients; falls back to `EmailRecipients` |
| `ManageScpPolicy` | `true` | `false` = notifications only, no SCP changes |
| `OrganizationId` | *(empty)* | `o-xxx` — scopes IAM to your org (recommended) |
| `EnableServiceApprovalWorkflow` | `true` | Track services pending manual approval |

### Exports (consumed by Stack 2)

Stack 1 exports 12 values — Stack 2 imports them all automatically via `InfrastructureStackName`.

| Export key | Used for |
|------------|----------|
| `LambdaRoleArn` | Lambda execution role |
| `ServiceRegistryTableName` | DynamoDB env var + alarm dimension |
| `ApprovedServicesTableName` | DynamoDB env var + alarm dimension |
| `PendingRegionalServicesTableName` | DynamoDB env var |
| `BaselineSnapshotsBucketName` | S3 env var |
| `AlertsTopicArn` | All 10 alarm actions |
| `EmailRecipientsValue` | Lambda env var |
| `SenderEmailValue` | Lambda env var |
| `ApprovalRecipientsResolved` | Lambda env var (resolved with fallback) |
| `ManageScpPolicyValue` | Lambda env var |
| `EnableServiceApprovalWorkflowValue` | Lambda env var |

---

## Stack 2 — Application

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InfrastructureStackName` | `aws-service-monitor-infra` | **Must match your infra stack name** |
| `ScpName` | `blacklist` | Name of the SCP to manage |
| `ScpSid` | `BlockNewServices` | Statement ID updated in the SCP |
| `RequireScpApproval` | `true` | `true` = notify only; `false` = auto-apply |
| `ApprovedServices` | `[]` | JSON array of services excluded from deny-list |
| `ScheduleExpression` | `cron(0 8 * * ? *)` | EventBridge schedule |
| `EnableCloudWatchDashboard` | `true` | Create CloudWatch dashboard |

### JSON array parameters

Several parameters expect a **JSON array string** — the Lambda reads them with `json.loads()`:

```
✅  ["ops@example.com","sec@example.com"]
✅  ["ec2","s3","lambda"]
❌  ops@example.com,sec@example.com   ← plain CSV causes a runtime error
```

---

## Updating

### Change email recipients or IAM config → redeploy Stack 1

```bash
# Edit infra-parameters.json, then:
aws cloudformation deploy \
  --template-file cloudformation/infrastructure.yaml \
  --stack-name aws-service-monitor-infra \
  --parameter-overrides file://cloudformation/infra-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-2
```

### Update Lambda code or alarms → redeploy Stack 2 only

```bash
# Edit application.yaml, then:
aws cloudformation deploy \
  --template-file cloudformation/application.yaml \
  --stack-name aws-service-monitor-app \
  --parameter-overrides file://cloudformation/app-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-2
```

---

## Destroying

Delete in reverse order — application stack first, then infrastructure:

```bash
aws cloudformation delete-stack --stack-name aws-service-monitor-app   --region eu-west-2
aws cloudformation wait stack-delete-complete --stack-name aws-service-monitor-app --region eu-west-2

aws cloudformation delete-stack --stack-name aws-service-monitor-infra --region eu-west-2
```

> ⚠️ **S3 Object Lock** — the baseline bucket uses GOVERNANCE retention (90 days). CloudFormation cannot delete it while objects exist. If the infra delete fails, manually remove the objects first:
>
> ```bash
> BUCKET="service-monitor-baseline-$(aws sts get-caller-identity --query Account --output text)-eu-west-2"
> aws s3api list-object-versions --bucket "$BUCKET" \
>   | python3 -c "
> import json,sys
> d=json.load(sys.stdin)
> [print(v['Key'],v['VersionId']) for v in d.get('Versions',[])+d.get('DeleteMarkers',[])]
> " | while read key ver; do
>     aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" \
>       --bypass-governance-retention
>   done
>
> # Retry the stack deletion
> aws cloudformation delete-stack --stack-name aws-service-monitor-infra --region eu-west-2
> ```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `ROLLBACK_COMPLETE` on first deploy | IAM name collision or S3 bucket already exists | Delete the failed stack, check for existing resources with the same names |
| Stack 2 fails with `Export not found` | Stack 1 not yet deployed or wrong stack name | Deploy Stack 1 first; verify `InfrastructureStackName` matches exactly |
| Lambda error: `json.loads` on env var | CSV instead of JSON array in a parameter | Use `["a","b"]` format in `EmailRecipients`, `ApprovedServices`, etc. |
| Emails not arriving | SES unverified or SNS subscription pending | Verify addresses in SES; click SNS confirmation links |
| `No updates are to be performed` | Stack already up to date | Not an error — no action needed |
| Template too large error | Using `--template-body` instead of `--template-file` | Always use `--template-file` with `aws cloudformation deploy` |

---

## Differences from the Terraform deployment

| Aspect | Terraform | CloudFormation |
|--------|-----------|----------------|
| State management | S3 backend + DynamoDB lock table | Managed by CloudFormation service |
| Bootstrap step | `terraform/bootstrap/` (one-time) | None required |
| Lambda code | Packaged as `lambda.zip`, stored in S3 | Embedded via `ZipFile` in `application.yaml` |
| SNS subscriptions | `count` over a list variable | Inline custom-resource Lambda |
| Stack structure | 7 Terraform modules | 2 CloudFormation stacks |
| Update experience | `terraform plan` shows diff | CloudFormation change-set |
