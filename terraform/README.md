# Terraform Infrastructure

This directory contains the Infrastructure-as-Code for the AWS Service Monitor system.

## Directory Structure

```
terraform/
├── README.md                    # This file
├── main.tf                      # Root module with component orchestration
├── providers.tf                 # AWS provider configuration
├── variables.tf                 # Input variables
├── outputs.tf                   # Root-level outputs
├── backend.tf                   # S3 remote state configuration
├── .terraform/                  # Terraform working directory (auto-generated)
├── .terraform.lock.hcl          # Provider version lock file
├── modules/                     # Reusable terraform modules
│   ├── dynamodb/               # DynamoDB tables for service tracking
│   ├── storage/                # S3 bucket for baseline snapshots
│   ├── notifications/          # SNS topics for alerts
│   ├── iam/                    # IAM roles and policies
│   ├── lambda/                 # Lambda function definition
│   ├── events/                 # EventBridge rule for scheduling
│   ├── monitoring/             # CloudWatch alarms and dashboards
│   └── iam-scp-events/        # CloudWatch rule for SCP changes (us-east-1)
└── bootstrap/                  # One-time setup for state backend
    ├── README.md              # Bootstrap documentation
    ├── main.tf                # S3 bucket and state backend resources
    ├── variables.tf           # Bootstrap variables
    └── terraform.tfstate*     # Local state (not committed)
```

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Access to AWS management account

### Step 1: Bootstrap State Backend (One-Time Only)

```bash
cd bootstrap
terraform init
AWS_PROFILE=lza-management terraform apply
cd ..
```

This creates the S3 bucket and DynamoDB table for Terraform state storage.

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

Required variables:
- `aws_region` - AWS region (typically eu-west-2)
- `email_recipients` - List of email addresses for notifications
- `sender_email` - Email address sending notifications (must be SES-verified)
- Other optional variables (see variables.tf)

### Step 3: Initialize Terraform

```bash
terraform init
```

### Step 4: Deploy

```bash
terraform plan
terraform apply
```

## Modules

Each module is self-contained with its own:
- `main.tf` - Resource definitions
- `variables.tf` - Input variables
- `outputs.tf` - Outputs exported to parent module

### Module Dependencies

```
root
├── data source: aws_caller_identity
├── aws_cloudwatch_log_group (created here for use by Lambda and Monitoring)
├── aws_iam_policy & aws_iam_role (permission boundary and temp role)
├── module.dynamodb
├── module.storage
├── module.notifications
├── module.iam_scp_events
├── module.iam (depends on: dynamodb, storage, notifications)
├── module.lambda (depends on: iam, dynamodb, storage, notifications)
├── module.events (depends on: lambda)
└── module.monitoring (depends on: lambda, dynamodb, events, notifications)
```

## Remote State

Terraform state is stored in S3 with:
- **Bucket**: `aws-service-monitor-tfstate-{account-id}-{region}`
- **Encryption**: AES256
- **Versioning**: Enabled
- **Locking**: S3 native object locking (GOVERNANCE mode, 90-day retention)
- **Access**: Private (public access blocked)

### Accessing Remote State

```bash
# List current state resources
terraform state list

# Show specific resource
terraform state show aws_lambda_function.service_monitor

# Check state in S3
aws s3 cp s3://aws-service-monitor-tfstate-556717286844-eu-west-2/terraform.tfstate - | jq .
```

## Common Terraform Commands

```bash
# Validate configuration syntax
terraform validate

# Format code
terraform fmt -recursive

# View plan before applying
terraform plan

# Apply infrastructure changes
terraform apply

# Destroy all resources
terraform destroy

# Refresh state from AWS
terraform refresh

# Import existing resource
terraform import module.lambda.aws_lambda_function.service_monitor aws-service-monitor
```

## Development Workflow

1. **Create/modify resources** in appropriate module
2. **Validate**: `terraform validate`
3. **Format**: `terraform fmt -recursive`
4. **Plan**: `terraform plan` (review changes)
5. **Apply**: `terraform apply`
6. **Test**: Manually invoke Lambda or check logs
7. **Commit**: Git commit changes (not .terraform/ or .tfstate files)

## Troubleshooting

### State Lock

If Terraform is stuck on a lock:

```bash
# View current locks
aws dynamodb scan --table-name aws-service-monitor-tfstate-lock --region eu-west-2

# Force unlock (use with caution)
terraform force-unlock <LOCK_ID>
```

### Provider Issues

```bash
# Upgrade providers
terraform init -upgrade

# Reinstall providers
rm -rf .terraform .terraform.lock.hcl
terraform init
```

### Module Issues

```bash
# Reinstall modules
rm -rf .terraform/modules
terraform init
```

## Security

- **Permission Boundary**: Lambda role is restricted via IAM permission boundary
- **State Encryption**: S3 backend encrypts state at rest (AES256)
- **Immutability**: Baseline snapshots stored with S3 Object Lock
- **Audit**: All changes logged in CloudWatch
- **Least Privilege**: Each module requests only required permissions

## Documentation

- See `../docs/DEPLOYMENT_GUIDE.md` for deployment instructions
- See `../docs/ARCHITECTURE.md` for system design
- See `../CLAUDE.md` for project context and commands
