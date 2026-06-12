# Terraform Backend Bootstrap

**One-Time Setup Only**: This directory is used to bootstrap the Terraform remote state backend. Run this ONCE before deploying the main infrastructure.

See `../docs/DEPLOYMENT_GUIDE.md` **Step 0** for complete deployment instructions.

## Quick Setup

1. Initialize the bootstrap Terraform (uses local state):
```bash
terraform init
```

2. Deploy the backend infrastructure (S3 bucket + DynamoDB table):
```bash
AWS_PROFILE=lza-management terraform apply
```

3. Return to root and initialize with S3 backend:
```bash
cd ..
terraform init
# Confirm migration of state to S3 when prompted
```

## Backend Features

- **S3 Bucket**: Stores Terraform state with native locking
  - Versioning enabled for state history
  - AES256 encryption enabled
  - Public access blocked
  - Object Lock (GOVERNANCE mode, 30-day retention) for WORM protection
  - S3 native locking prevents concurrent applies

## Cleanup

To destroy the backend infrastructure:
```bash
cd bootstrap
AWS_PROFILE=lza-management terraform destroy
```

⚠️ **Warning**: This will attempt to delete the S3 bucket containing Terraform state. 
Ensure no states are stored or migrate them first.

## Security Notes

- State files may contain sensitive data (credentials, etc.)
- Ensure IAM policies restrict access to the S3 bucket and DynamoDB table
- Object Lock provides protection against accidental/malicious deletion
- All data is encrypted at rest

## Troubleshooting

**"State already exists in S3"**: Run `terraform init` from root to migrate local state
**"Bucket already exists"**: Check AWS account for existing state buckets
**"Access Denied"**: Verify AWS credentials and IAM permissions

See parent directory `backend.tf` for the main project's backend configuration.
