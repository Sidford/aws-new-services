# SNS topic for operational alerts
resource "aws_sns_topic" "alerts" {
  name = "aws-service-monitor-alerts"

  tags = var.tags
}

# SNS subscriptions for alert email recipients
resource "aws_sns_topic_subscription" "alert_emails" {
  count     = length(var.email_recipients)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.email_recipients[count.index]
}
