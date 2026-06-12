variable "aws_region" {
  description = "AWS region for S3 bucket"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
