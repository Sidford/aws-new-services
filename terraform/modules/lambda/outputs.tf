output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.service_monitor.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.service_monitor.arn
}

output "lambda_function_version" {
  description = "Lambda function version"
  value       = aws_lambda_function.service_monitor.version
}
