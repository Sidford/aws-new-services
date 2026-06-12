output "scp_alert_topic_arn" {
  description = "SCP change alerts SNS topic ARN (us-east-1)"
  value       = aws_sns_topic.scp_change_alerts.arn
}

output "scp_alert_topic_name" {
  description = "SCP change alerts SNS topic name"
  value       = aws_sns_topic.scp_change_alerts.name
}
