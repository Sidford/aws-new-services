output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.lambda_logs.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = try(aws_cloudwatch_dashboard.service_monitor[0].dashboard_name, null)
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = var.enable_cloudwatch_dashboard ? "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=aws-service-monitor" : null
}
