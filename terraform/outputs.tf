output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = module.lambda.lambda_function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = module.lambda.lambda_function_arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table storing service registry"
  value       = module.dynamodb.service_registry_table_name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule for scheduling"
  value       = module.events.event_rule_name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = module.iam.lambda_role_arn
}

output "baseline_snapshot_bucket" {
  description = "S3 bucket for immutable baseline snapshots (T004 mitigation)"
  value       = module.storage.baseline_bucket_id
}

output "baseline_snapshot_bucket_arn" {
  description = "ARN of the baseline snapshot bucket"
  value       = module.storage.baseline_bucket_arn
}

output "alert_topic_arn" {
  description = "ARN of the SNS topic for operational alerts"
  value       = module.notifications.alert_topic_arn
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch Dashboard"
  value       = module.monitoring.dashboard_url
}

output "pending_regional_services_table" {
  description = "DynamoDB table for tracking services pending regional availability"
  value       = module.dynamodb.pending_regional_services_table_name
}

output "monitored_region" {
  description = "AWS region being monitored for new service availability"
  value       = var.aws_region
}

# Additional outputs for convenience
output "approved_services_table_name" {
  description = "DynamoDB table for tracking approved services"
  value       = module.dynamodb.approved_services_table_name
}

output "scp_alert_topic_arn" {
  description = "SNS topic ARN for SCP change alerts (us-east-1)"
  value       = module.iam_scp_events.scp_alert_topic_arn
}
