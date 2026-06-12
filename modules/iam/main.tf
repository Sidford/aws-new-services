# Permission boundary for Lambda role (T015 mitigation)
resource "aws_iam_policy" "lambda_permission_boundary" {
  name        = "aws-service-monitor-lambda-boundary"
  description = "Permission boundary limiting Lambda to only required services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDynamoDBOperations"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3Operations"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectVersionTagging",
          "s3:ListBucket"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowOrganizationsOperations"
        Effect = "Allow"
        Action = [
          "organizations:ListPolicies",
          "organizations:DescribePolicy",
          "organizations:UpdatePolicy"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSESOperations"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchAndLogging"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowKMSOperations"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNSOperations"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDangerousActions"
        Effect = "Deny"
        Action = [
          "iam:*",
          "sts:AssumeRole",
          "ec2:TerminateInstances",
          "rds:DeleteDBInstance",
          "rds:DeleteDBCluster",
          "s3:DeleteBucket",
          "organizations:DetachPolicy",
          "organizations:DeletePolicy"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

# Lambda execution role with permission boundary
resource "aws_iam_role" "lambda_role" {
  name                 = "aws-service-monitor-lambda-role"
  permissions_boundary = aws_iam_policy.lambda_permission_boundary.arn

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
        Resource = var.dynamodb_table_arns.service_registry
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query"
        ]
        Resource = [
          var.dynamodb_table_arns.approved_services,
          var.dynamodb_gsi_arns.approved_services_index
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          var.dynamodb_table_arns.pending_regional_services,
          var.dynamodb_gsi_arns.pending_regional_index
        ]
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
        Resource = "arn:aws:organizations::${var.aws_account_id}:policy/p-*"
        Condition = {
          StringEquals = {
            "organizations:PolicyType" = "SERVICE_CONTROL_POLICY"
          }
        }
      }
    ]
  })
}

# IAM policy for Lambda to write baseline snapshots to S3
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
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = var.s3_bucket_arn
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
        Resource = var.sns_alert_topic_arn
      }
    ]
  })
}

# IAM policy for Lambda to write logs
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
        Resource = "${var.log_group_arn}:*"
      }
    ]
  })
}

# IAM policy for Lambda to use the DynamoDB KMS key
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
        Resource = var.kms_key_arn
      }
    ]
  })
}
