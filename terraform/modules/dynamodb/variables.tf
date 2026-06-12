variable "aws_region" {
  description = "AWS region for KMS key and tables"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda execution role ARN for KMS key policy"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
