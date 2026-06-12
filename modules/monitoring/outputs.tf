output "log_group_name" {
  description = "CloudWatch log group name"
  value       = var.log_group_name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN (computed)"
  value       = "arn:aws:logs:${var.aws_region}:*:log-group:${var.log_group_name}"
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = try(aws_cloudwatch_dashboard.service_monitor[0].dashboard_name, null)
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = var.enable_cloudwatch_dashboard ? "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=aws-service-monitor" : null
}
