# Data source for existing role (if provided)
data "aws_iam_role" "existing" {
  count = var.existing_role_id != "" ? 1 : 0
  name  = var.existing_role_id
}

# Organization ID needed to construct valid SCP ARNs (policy/<org-id>/service_control_policy/<policy-id>)
# Only fetched when SCP management is enabled — avoids requiring organizations:DescribeOrganization
# in notifications-only deployments or from member accounts.
data "aws_organizations_organization" "current" {
  count = var.manage_scp_policy ? 1 : 0
}

# No role creation here - role is created at root module with permission boundary
# This module only attaches policies to the existing role
locals {
  lambda_role_id = data.aws_iam_role.existing[0].id
}

# IAM policy for Lambda to access DynamoDB
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "lambda-dynamodb-policy"
  role = local.lambda_role_id

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
# Only created when SCP management is enabled — withheld in notifications-only deployments.
resource "aws_iam_role_policy" "lambda_scp_policy" {
  count = var.manage_scp_policy ? 1 : 0

  name = "lambda-scp-policy"
  role = local.lambda_role_id

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
        Resource = "arn:aws:organizations::${var.aws_account_id}:policy/${data.aws_organizations_organization.current[0].id}/service_control_policy/p-*"
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
  role = local.lambda_role_id

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
  role = local.lambda_role_id

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
  role = local.lambda_role_id

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
  role = local.lambda_role_id

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
  role = local.lambda_role_id

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
  role = local.lambda_role_id

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
