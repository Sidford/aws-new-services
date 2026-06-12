variable "schedule_expression" {
  description = "EventBridge schedule expression for Lambda invocation"
  type        = string
}

variable "lambda_function_arn" {
  description = "Lambda function ARN"
  type        = string
}

variable "lambda_function_name" {
  description = "Lambda function name"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
