# CloudWatch log group for Lambda function
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = 90

  tags = var.tags
}

# CloudWatch metric filter for permission boundary deny hits
resource "aws_cloudwatch_log_metric_filter" "permission_boundary_deny" {
  name           = "permission-boundary-deny-hits"
  log_group_name = aws_cloudwatch_log_group.lambda_logs.name
  pattern        = "\"Baseline update failed\""

  metric_transformation {
    name          = "PermissionBoundaryDenyHits"
    namespace     = "ServiceMonitor"
    default_value = 0
    value         = "1"
  }
}

# Lambda errors alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

# Lambda duration high alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

# Lambda timeout alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

# DynamoDB read throttles alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_registry_table_name
  }

  tags = var.tags
}

# DynamoDB write throttles alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_registry_table_name
  }

  tags = var.tags
}

# Baseline integrity alarm
resource "aws_cloudwatch_metric_alarm" "baseline_integrity" {
  alarm_name          = "service-monitor-baseline-integrity-violation"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "BaselineIntegrityStatus"
  namespace           = "ServiceMonitor"
  period              = "300"
  statistic           = "Minimum"
  threshold           = "0"
  alarm_description   = "CRITICAL: Baseline integrity verification failed - possible tampering detected"
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  tags = var.tags
}

# Missed execution alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "breaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  tags = var.tags
}

# DynamoDB unusual writes alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_registry_table_name
  }

  tags = var.tags
}

# Approved services unusual writes alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_approved_services_table_name
  }

  tags = var.tags
}

# EventBridge rule disabled alarm
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
  alarm_actions       = [var.sns_alert_topic_arn]
  treat_missing_data  = "breaching"

  dimensions = {
    Rule = var.eventbridge_rule_name
  }

  tags = var.tags
}

# Permission boundary deny hits alarm
resource "aws_cloudwatch_metric_alarm" "permission_boundary_deny" {
  alarm_name          = "service-monitor-permission-boundary-deny"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "PermissionBoundaryDenyHits"
  namespace           = "ServiceMonitor"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Alert on permission boundary Deny hits (high-fidelity compromise signal for T011/T015)"
  alarm_actions       = [var.sns_alert_topic_arn]

  tags = var.tags
}

# Optional CloudWatch dashboard
resource "aws_cloudwatch_dashboard" "service_monitor" {
  count          = var.enable_cloudwatch_dashboard ? 1 : 0
  dashboard_name = "aws-service-monitor"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [["AWS/Lambda", "Invocations", { stat = "Sum", label = "Invocations" }]]
          period = 3600
          stat   = "Sum"
          region = var.aws_region
          title  = "Lambda Invocations (Daily)"
          yAxis = {
            left = { min = 0 }
          }
        }
        width = 12
        height = 6
        x = 0
        y = 0
      },
      {
        type = "metric"
        properties = {
          metrics = [["AWS/Lambda", "Errors", { stat = "Sum", label = "Errors" }]]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "Lambda Errors (5-minute)"
          yAxis = {
            left = { min = 0 }
          }
          alarm_colors = {
            alarm_color  = "#d13212"
            ok_color     = "#2ca02c"
            insufficient_data_color = "#cccccc"
          }
        }
        width = 12
        height = 6
        x = 12
        y = 0
      }
    ]
  })
}
