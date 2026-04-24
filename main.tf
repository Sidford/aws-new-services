# DynamoDB table for tracking monitored services
resource "aws_dynamodb_table" "service_registry" {
  name           = "aws-service-monitor-registry"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  point_in_time_recovery_specification {
    enabled = true
  }

  ttl {
    attribute_name = "expiration_time"
    enabled        = false
  }

  tags = var.tags
}

# IAM role for Lambda function
resource "aws_iam_role" "lambda_role" {
  name = "aws-service-monitor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# IAM policy for Lambda to access DynamoDB
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "lambda-dynamodb-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.service_registry.arn
      }
    ]
  })
}

# IAM policy for Lambda to access Organizations and SCP
resource "aws_iam_role_policy" "lambda_scp_policy" {
  name = "lambda-scp-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "organizations:ListPolicies",
          "organizations:DescribePolicy",
          "organizations:UpdatePolicy"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM policy for Lambda to send emails via SES
resource "aws_iam_role_policy" "lambda_ses_policy" {
  name = "lambda-ses-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM policy for Lambda to write logs (restricted to specific log group)
resource "aws_iam_role_policy" "lambda_logs_policy" {
  name = "lambda-logs-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
      }
    ]
  })
}

# Archive the Lambda function code
data "archive_file" "lambda_code" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

# Lambda function
resource "aws_lambda_function" "service_monitor" {
  filename         = data.archive_file.lambda_code.output_path
  function_name    = "aws-service-monitor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.lambda_handler"
  source_code_hash = data.archive_file.lambda_code.output_base64sha256
  timeout          = 300
  runtime          = "python3.11"

  environment {
    variables = {
      DYNAMODB_TABLE        = aws_dynamodb_table.service_registry.name
      SCP_NAME              = var.scp_name
      EMAIL_RECIPIENTS      = jsonencode(var.email_recipients)
      SENDER_EMAIL          = var.sender_email
      AWS_REGION            = var.aws_region
      REQUIRE_APPROVAL      = var.require_scp_approval ? "true" : "false"
    }
  }

  tags = var.tags
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/aws-service-monitor"
  retention_in_days = 14

  tags = var.tags
}

# EventBridge rule for scheduling
resource "aws_cloudwatch_event_rule" "daily_monitor" {
  name                = "aws-service-monitor-daily"
  description         = "Trigger AWS service monitor daily"
  schedule_expression = var.schedule_expression

  tags = var.tags
}

# EventBridge target
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_monitor.name
  target_id = "AWSServiceMonitorLambda"
  arn       = aws_lambda_function.service_monitor.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.service_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_monitor.arn
}
