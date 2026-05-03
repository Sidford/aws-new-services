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

# T005: AWS Organizations events are only recorded in CloudTrail in us-east-1.
# A second provider alias is required to deploy the EventBridge rule that
# detects SCP changes in that region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Get current AWS account ID for S3 bucket naming
data "aws_caller_identity" "current" {}
