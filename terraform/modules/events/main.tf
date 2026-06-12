# EventBridge rule to trigger Lambda daily
resource "aws_cloudwatch_event_rule" "daily_monitor" {
  name                = "aws-service-monitor-daily"
  description         = "Trigger AWS service monitor daily"
  schedule_expression = var.schedule_expression

  tags = var.tags
}

# EventBridge target: Lambda function
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_monitor.name
  target_id = "AWSServiceMonitorLambda"
  arn       = var.lambda_function_arn
}

# Lambda permission for EventBridge to invoke the function
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_monitor.arn
}
