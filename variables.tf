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

variable "email_recipients" {
  description = "Email addresses to receive notifications"
  type        = list(string)
}

variable "sender_email" {
  description = "Email address to send from (must be verified in SES)"
  type        = string
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
