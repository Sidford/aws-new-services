terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  bucket_name = "aws-service-monitor-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

data "aws_caller_identity" "current" {}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  tags = {
    Name        = "Terraform State"
    Environment = "Management"
    Purpose     = "Terraform State Backend"
  }
}

# Enable versioning for state bucket
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Disabled"
  }
}

# Enable encryption for state bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable object lock for WORM protection (requires versioning enabled first)
resource "aws_s3_bucket_object_lock_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 30
    }
  }
}

# Outputs
output "tfstate_bucket" {
  description = "Terraform state S3 bucket name"
  value       = aws_s3_bucket.tfstate.id
}
