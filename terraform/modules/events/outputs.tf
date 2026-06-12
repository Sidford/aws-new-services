output "event_rule_name" {
  description = "EventBridge rule name"
  value       = aws_cloudwatch_event_rule.daily_monitor.name
}

output "event_rule_arn" {
  description = "EventBridge rule ARN"
  value       = aws_cloudwatch_event_rule.daily_monitor.arn
}

output "event_rule_schedule" {
  description = "EventBridge rule schedule expression"
  value       = aws_cloudwatch_event_rule.daily_monitor.schedule_expression
}
