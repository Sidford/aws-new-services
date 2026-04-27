output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.service_monitor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.service_monitor.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table storing service registry"
  value       = aws_dynamodb_table.service_registry.name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule for scheduling"
  value       = aws_cloudwatch_event_rule.daily_monitor.name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = aws_iam_role.lambda_role.arn
}

output "baseline_snapshot_bucket" {
  description = "S3 bucket for immutable baseline snapshots (T004 mitigation)"
  value       = aws_s3_bucket.baseline_snapshots.id
}

output "baseline_snapshot_bucket_arn" {
  description = "ARN of the baseline snapshot bucket"
  value       = aws_s3_bucket.baseline_snapshots.arn
}

output "alert_topic_arn" {
  description = "ARN of the SNS topic for operational alerts"
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch Dashboard"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=aws-service-monitor"
}
