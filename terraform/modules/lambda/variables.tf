variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "aws-service-monitor"
}

variable "role_arn" {
  description = "Lambda execution role ARN"
  type        = string
}

variable "dynamodb_table_names" {
  description = "Map of DynamoDB table names"
  type = object({
    service_registry          = string
    approved_services         = string
    pending_regional_services = string
  })
}

variable "s3_bucket_name" {
  description = "S3 bucket name for baseline snapshots"
  type        = string
}

variable "sns_alert_topic_arn" {
  description = "SNS alert topic ARN"
  type        = string
}

variable "log_group_arn" {
  description = "CloudWatch log group ARN"
  type        = string
}

# Lambda configuration variables
variable "scp_name" {
  description = "SCP policy name"
  type        = string
}

variable "scp_sid" {
  description = "SCP statement ID"
  type        = string
  default     = "BlockNewServices"
}

variable "manage_scp_policy" {
  description = "Enable/disable SCP policy management"
  type        = bool
  default     = true
}

variable "require_scp_approval" {
  description = "Require approval before SCP changes"
  type        = bool
  default     = true
}

variable "email_recipients" {
  description = "Email addresses to receive notifications"
  type        = list(string)
}

variable "sender_email" {
  description = "Email address to send from"
  type        = string
}

variable "approved_services" {
  description = "List of approved services"
  type        = list(string)
  default     = []
}

variable "enable_service_approval_workflow" {
  description = "Enable service approval workflow"
  type        = bool
  default     = true
}

variable "approval_recipients" {
  description = "Email addresses for approval requests"
  type        = list(string)
  default     = []
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
