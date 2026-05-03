# CloudWatch Alarms for AWS Service Monitor
# Alerts on errors, performance issues, and integrity violations

# Lambda Function Errors - CRITICAL
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "service-monitor-lambda-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "3600"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert when Lambda function encounters errors"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.service_monitor.function_name
  }

  tags = var.tags
}

# Lambda Function Duration High - WARNING
resource "aws_cloudwatch_metric_alarm" "lambda_duration_high" {
  alarm_name          = "service-monitor-lambda-duration-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Average"
  threshold           = "270000"
  alarm_description   = "Alert when Lambda duration is high (approaching 300s timeout, 90% threshold)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.service_monitor.function_name
  }

  tags = var.tags
}

# Lambda Function Timeout - CRITICAL
resource "aws_cloudwatch_metric_alarm" "lambda_timeout" {
  alarm_name          = "service-monitor-lambda-timeout"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "300000"
  alarm_description   = "Alert when Lambda execution timeout occurs"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.service_monitor.function_name
  }

  tags = var.tags
}

# DynamoDB Read Throttles - WARNING
resource "aws_cloudwatch_metric_alarm" "dynamodb_read_throttles" {
  alarm_name          = "service-monitor-dynamodb-read-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "UserErrors"
  namespace           = "AWS/DynamoDB"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert when DynamoDB read operations are throttled"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.service_registry.name
  }

  tags = var.tags
}

# DynamoDB Write Throttles - WARNING
resource "aws_cloudwatch_metric_alarm" "dynamodb_write_throttles" {
  alarm_name          = "service-monitor-dynamodb-write-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "UserErrors"
  namespace           = "AWS/DynamoDB"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert when DynamoDB write operations are throttled"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.service_registry.name
  }

  tags = var.tags
}

# Baseline Integrity Violation - CRITICAL
resource "aws_cloudwatch_metric_alarm" "baseline_integrity" {
  alarm_name          = "service-monitor-baseline-integrity-violation"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "BaselineIntegrityStatus"
  namespace           = "AWS/ServiceMonitor"
  period              = "300"
  statistic           = "Minimum"
  threshold           = "0"
  alarm_description   = "CRITICAL: Baseline integrity verification failed - possible tampering detected"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = var.tags
}

# Missed Execution - WARNING
resource "aws_cloudwatch_metric_alarm" "missed_execution" {
  alarm_name          = "service-monitor-missed-execution"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "Invocations"
  namespace           = "AWS/Lambda"
  period              = "86400"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert if scheduled Lambda execution was missed (no invocation in 24 hours)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching"

  dimensions = {
    FunctionName = aws_lambda_function.service_monitor.function_name
  }

  tags = var.tags
}

# DynamoDB Unusual Write Volume - T003 mitigation
# The Lambda writes once per day; sustained high write volume outside that window
# indicates unauthorized direct table access.
resource "aws_cloudwatch_metric_alarm" "dynamodb_unusual_writes" {
  alarm_name          = "service-monitor-dynamodb-unusual-writes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ConsumedWriteCapacityUnits"
  namespace           = "AWS/DynamoDB"
  period              = "3600"
  statistic           = "Sum"
  threshold           = "500"
  alarm_description   = "Unusually high DynamoDB write volume — possible unauthorized direct table access (T003)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.service_registry.name
  }

  tags = var.tags
}

# Approved-Services Table Write Anomaly - T015 mitigation
# Any write to this table outside the daily Lambda window is suspicious —
# legitimate approvals flow via terraform.tfvars, not direct DynamoDB writes.
resource "aws_cloudwatch_metric_alarm" "approved_services_unusual_writes" {
  alarm_name          = "service-monitor-approved-services-unusual-writes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ConsumedWriteCapacityUnits"
  namespace           = "AWS/DynamoDB"
  period              = "3600"
  statistic           = "Sum"
  threshold           = "50"
  alarm_description   = "Unexpected writes to approved-services table — possible approval workflow bypass attempt (T015)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.approved_services.name
  }

  tags = var.tags
}

# EventBridge Rule State - CRITICAL
resource "aws_cloudwatch_metric_alarm" "eventbridge_rule_disabled" {
  alarm_name          = "service-monitor-eventbridge-rule-disabled"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "TriggeredRules"
  namespace           = "AWS/Events"
  period              = "86400"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert if EventBridge rule is disabled or not triggering (no rules triggered in 24 hours)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching"

  dimensions = {
    Rule = aws_cloudwatch_event_rule.daily_monitor.name
  }

  tags = var.tags
}
