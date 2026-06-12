variable "lambda_function_name" {
  description = "Lambda function name"
  type        = string
}

variable "lambda_function_arn" {
  description = "Lambda function ARN"
  type        = string
}

variable "dynamodb_registry_table_name" {
  description = "DynamoDB service registry table name"
  type        = string
}

variable "dynamodb_approved_services_table_name" {
  description = "DynamoDB approved services table name"
  type        = string
}

variable "eventbridge_rule_name" {
  description = "EventBridge rule name for alarms"
  type        = string
}

variable "sns_alert_topic_arn" {
  description = "SNS alert topic ARN"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "enable_cloudwatch_dashboard" {
  description = "Enable/disable CloudWatch dashboard creation"
  type        = bool
  default     = true
}

variable "log_group_name" {
  description = "CloudWatch log group name for Lambda function"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
