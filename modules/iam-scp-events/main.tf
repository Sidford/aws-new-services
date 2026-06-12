terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# SNS topic in us-east-1 for SCP change alerts
# (Organizations CloudTrail events are only available in us-east-1 EventBridge)
resource "aws_sns_topic" "scp_change_alerts" {
  provider = aws.us_east_1
  name     = "aws-service-monitor-scp-change-alerts"
  tags     = var.tags
}

# SNS subscriptions for SCP change alerts
resource "aws_sns_topic_subscription" "scp_change_alert_emails" {
  provider  = aws.us_east_1
  count     = length(var.email_recipients)
  topic_arn = aws_sns_topic.scp_change_alerts.arn
  protocol  = "email"
  endpoint  = var.email_recipients[count.index]
}

# SNS topic policy to allow EventBridge to publish
resource "aws_sns_topic_policy" "scp_change_alerts" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.scp_change_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.scp_change_alerts.arn
      }
    ]
  })
}

# EventBridge rule in us-east-1 to detect any SCP policy modification
resource "aws_cloudwatch_event_rule" "scp_changes" {
  provider    = aws.us_east_1
  name        = "aws-service-monitor-scp-changes"
  description = "Alert on any direct SCP policy modification outside the Lambda workflow (T005)"

  event_pattern = jsonencode({
    source      = ["aws.organizations"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["UpdatePolicy", "DeletePolicy", "CreatePolicy", "AttachPolicy", "DetachPolicy"]
    }
  })

  tags = var.tags
}

# EventBridge target to publish to SNS
resource "aws_cloudwatch_event_target" "scp_changes_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.scp_changes.name
  target_id = "scp-change-sns-alert"
  arn       = aws_sns_topic.scp_change_alerts.arn
}
