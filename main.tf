# KMS key for DynamoDB encryption (T003 mitigation)
resource "aws_kms_key" "dynamodb" {
  description             = "CMK for aws-service-monitor DynamoDB tables"
  enable_key_rotation     = true
  deletion_window_in_days = 14

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_role.arn
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/aws-service-monitor-dynamodb"
  target_key_id = aws_kms_key.dynamodb.key_id
}

# S3 bucket for immutable baseline snapshots (T004 mitigation)
resource "aws_s3_bucket" "baseline_snapshots" {
  bucket = "service-monitor-baseline-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 90  # 90-day retention for immutability
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    id     = "delete_old_snapshots"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# DynamoDB table for tracking monitored services
resource "aws_dynamodb_table" "service_registry" {
  name           = "aws-service-monitor-registry"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  ttl {
    attribute_name = "expiration_time"
    enabled        = false
  }

  tags = var.tags
}

# DynamoDB table for tracking approved services and approval requests
resource "aws_dynamodb_table" "approved_services" {
  name           = "aws-service-monitor-approved-services"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  attribute {
    name = "approval_status"
    type = "S"
  }

  global_secondary_index {
    name            = "approval-status-index"
    hash_key        = "approval_status"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
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
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem"
        ]
        Resource = aws_dynamodb_table.service_registry.arn
      },
      {
        # T015: approved-services is read + PutItem (pending records) only.
        # UpdateItem and Scan are withheld — Lambda cannot promote a record to
        # 'approved' status nor enumerate the table without going through the GSI.
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.approved_services.arn,
          "${aws_dynamodb_table.approved_services.arn}/index/*"
        ]
      }
    ]
  })
}

# IAM policy for Lambda to access Organizations and SCP (T005 mitigation)
resource "aws_iam_role_policy" "lambda_scp_policy" {
  name = "lambda-scp-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["organizations:ListPolicies"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "organizations:PolicyType" = "SERVICE_CONTROL_POLICY"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["organizations:DescribePolicy", "organizations:UpdatePolicy"]
        Resource = "arn:aws:organizations::${data.aws_caller_identity.current.account_id}:policy/p-*"
        Condition = {
          StringEquals = {
            "organizations:PolicyType" = "SERVICE_CONTROL_POLICY"
          }
        }
      }
    ]
  })
}

# T005: SNS topic in us-east-1 for SCP change alerts (Organizations CloudTrail
# events are only available in us-east-1 EventBridge).
resource "aws_sns_topic" "scp_change_alerts" {
  provider = aws.us_east_1
  name     = "aws-service-monitor-scp-change-alerts"
  tags     = var.tags
}

resource "aws_sns_topic_subscription" "scp_change_alert_emails" {
  provider  = aws.us_east_1
  count     = length(var.email_recipients)
  topic_arn = aws_sns_topic.scp_change_alerts.arn
  protocol  = "email"
  endpoint  = var.email_recipients[count.index]
}

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

resource "aws_cloudwatch_event_target" "scp_changes_sns" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.scp_changes.name
  target_id = "scp-change-sns-alert"
  arn       = aws_sns_topic.scp_change_alerts.arn
}

# IAM policy for Lambda to write baseline snapshots to S3 (T004 mitigation)
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "lambda-s3-baseline-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.baseline_snapshots.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.baseline_snapshots.arn
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

# IAM policy for Lambda to publish CloudWatch metrics
resource "aws_iam_role_policy" "lambda_cloudwatch_metrics_policy" {
  name = "lambda-cloudwatch-metrics-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM policy for Lambda to publish alerts via SNS
resource "aws_iam_role_policy" "lambda_sns_policy" {
  name = "lambda-sns-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.alerts.arn
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

# IAM policy for Lambda to use the DynamoDB KMS key (T003 mitigation)
resource "aws_iam_role_policy" "lambda_kms_policy" {
  name = "lambda-kms-dynamodb-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.dynamodb.arn
      }
    ]
  })
}

# SNS topic for CloudWatch Alarms and operational alerts
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
      DYNAMODB_TABLE                   = aws_dynamodb_table.service_registry.name
      APPROVED_SERVICES_TABLE          = aws_dynamodb_table.approved_services.name
      SCP_NAME                         = var.scp_name
      EMAIL_RECIPIENTS                 = jsonencode(var.email_recipients)
      SENDER_EMAIL                     = var.sender_email
      REQUIRE_APPROVAL                 = var.require_scp_approval ? "true" : "false"
      MANAGE_SCP_POLICY                = var.manage_scp_policy ? "true" : "false"
      BASELINE_SNAPSHOT_BUCKET         = aws_s3_bucket.baseline_snapshots.id
      ALERT_TOPIC_ARN                  = aws_sns_topic.alerts.arn
      ENABLE_SERVICE_APPROVAL_WORKFLOW = var.enable_service_approval_workflow ? "true" : "false"
      APPROVED_SERVICES_LIST           = jsonencode(var.approved_services)
      APPROVAL_RECIPIENTS              = jsonencode(length(var.approval_recipients) > 0 ? var.approval_recipients : var.email_recipients)
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
