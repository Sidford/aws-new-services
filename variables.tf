variable "aws_region" {
  description = "AWS region for the management account"
  type        = string
  default     = "us-east-1"
}

variable "schedule_expression" {
  description = "EventBridge schedule expression for daily monitoring"
  type        = string
  default     = "cron(0 8 * * ? *)" # 8 AM UTC daily
}

variable "scp_name" {
  description = "Name of the Service Control Policy to manage"
  type        = string
  default     = "blacklist"
}

variable "scp_sid" {
  description = "Statement ID (Sid) in the SCP to update with new services"
  type        = string
  default     = "BlockNewServices"
}

variable "email_recipients" {
  description = "Email addresses to receive notifications"
  type        = list(string)
}

variable "sender_email" {
  description = "Email address to send from (must be verified in SES)"
  type        = string
}

variable "require_scp_approval" {
  description = "Require manual approval before updating SCP (dry-run mode)"
  type        = bool
  default     = true
}

variable "manage_scp_policy" {
  description = "Enable/disable automatic SCP policy management. When disabled, only notifications are sent."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "AWS-Service-Monitor"
    Environment = "Management"
    ManagedBy   = "Terraform"
  }
}
