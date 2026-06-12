output "alert_topic_arn" {
  description = "SNS alert topic ARN"
  value       = aws_sns_topic.alerts.arn
}

output "alert_topic_name" {
  description = "SNS alert topic name"
  value       = aws_sns_topic.alerts.name
}
