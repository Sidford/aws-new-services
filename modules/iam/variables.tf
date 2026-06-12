variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "existing_role_id" {
  description = "ID of existing Lambda IAM role (if provided, role creation is skipped)"
  type        = string
  default     = ""
}

variable "dynamodb_table_arns" {
  description = "Map of DynamoDB table ARNs"
  type = object({
    service_registry          = string
    approved_services         = string
    pending_regional_services = string
  })
}

variable "dynamodb_gsi_arns" {
  description = "Map of DynamoDB Global Secondary Index ARNs"
  type = object({
    approved_services_index      = string
    pending_regional_index       = string
  })
}

variable "kms_key_arn" {
  description = "KMS key ARN for DynamoDB encryption"
  type        = string
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN for baseline snapshots"
  type        = string
}

variable "sns_alert_topic_arn" {
  description = "SNS alert topic ARN"
  type        = string
}

variable "log_group_arn" {
  description = "CloudWatch log group ARN for Lambda"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
