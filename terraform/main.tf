# Data source for current AWS account ID
data "aws_caller_identity" "current" {}

# CloudWatch log group for Lambda (created here to resolve circular dependency)
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/aws-service-monitor"
  retention_in_days = 90

  tags = var.tags
}

# ============================================================================
# Create Permission Boundary First
# ============================================================================
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

# ============================================================================
# Create Lambda Role (with boundary applied)
# ============================================================================
resource "aws_iam_role" "lambda_role_temp" {
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

# ============================================================================
# Module: DynamoDB (Depends on: Lambda role temp)
# ============================================================================
module "dynamodb" {
  source = "./modules/dynamodb"

  aws_region      = var.aws_region
  aws_account_id  = data.aws_caller_identity.current.account_id
  lambda_role_arn = aws_iam_role.lambda_role_temp.arn
  tags            = var.tags
}

# ============================================================================
# Module: Storage (No dependencies)
# ============================================================================
module "storage" {
  source = "./modules/storage"

  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id
  tags           = var.tags
}

# ============================================================================
# Module: Notifications (No dependencies)
# ============================================================================
module "notifications" {
  source = "./modules/notifications"

  email_recipients = var.email_recipients
  tags             = var.tags
}

# ============================================================================
# Module: SCP Events (us-east-1, No dependencies on other modules)
# ============================================================================
module "iam_scp_events" {
  source = "./modules/iam-scp-events"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  email_recipients = var.email_recipients
  tags             = var.tags
}

# ============================================================================
# Module: IAM (Depends on: DynamoDB, Storage, Notifications, Log Group, Lambda role temp)
# ============================================================================
module "iam" {
  source = "./modules/iam"

  depends_on = [aws_iam_role.lambda_role_temp]

  aws_account_id     = data.aws_caller_identity.current.account_id
  existing_role_id   = aws_iam_role.lambda_role_temp.name

  dynamodb_table_arns = {
    service_registry          = module.dynamodb.service_registry_table_arn
    approved_services         = module.dynamodb.approved_services_table_arn
    pending_regional_services = module.dynamodb.pending_regional_services_table_arn
  }

  dynamodb_gsi_arns = {
    approved_services_index = "${module.dynamodb.approved_services_table_arn}/index/approval-status-index"
    pending_regional_index  = module.dynamodb.pending_regional_gsi_arn
  }

  manage_scp_policy      = var.manage_scp_policy
  kms_key_arn            = module.dynamodb.kms_key_arn
  s3_bucket_arn          = module.storage.baseline_bucket_arn
  sns_alert_topic_arn    = module.notifications.alert_topic_arn
  log_group_arn          = aws_cloudwatch_log_group.lambda_logs.arn
  tags                   = var.tags
}

# ============================================================================
# Module: Lambda (Depends on: IAM, DynamoDB, Storage, Notifications)
# ============================================================================
module "lambda" {
  source = "./modules/lambda"

  function_name = "aws-service-monitor"
  role_arn      = module.iam.lambda_role_arn

  dynamodb_table_names = {
    service_registry          = module.dynamodb.service_registry_table_name
    approved_services         = module.dynamodb.approved_services_table_name
    pending_regional_services = module.dynamodb.pending_regional_services_table_name
  }

  s3_bucket_name           = module.storage.baseline_bucket_id
  sns_alert_topic_arn      = module.notifications.alert_topic_arn
  log_group_arn            = aws_cloudwatch_log_group.lambda_logs.arn
  scp_name                 = var.scp_name
  scp_sid                  = var.scp_sid
  manage_scp_policy        = var.manage_scp_policy
  require_scp_approval     = var.require_scp_approval
  email_recipients         = var.email_recipients
  sender_email             = var.sender_email
  approved_services        = var.approved_services
  enable_service_approval_workflow = var.enable_service_approval_workflow
  approval_recipients      = var.approval_recipients
  aws_region               = var.aws_region
  tags                     = var.tags
}

# ============================================================================
# Module: Events (Depends on: Lambda)
# ============================================================================
module "events" {
  source = "./modules/events"

  schedule_expression   = var.schedule_expression
  lambda_function_arn   = module.lambda.lambda_function_arn
  lambda_function_name  = module.lambda.lambda_function_name
  tags                  = var.tags
}

# ============================================================================
# Module: Monitoring (Depends on: Lambda, DynamoDB, Events, Notifications)
# ============================================================================
module "monitoring" {
  source = "./modules/monitoring"

  lambda_function_name                = module.lambda.lambda_function_name
  lambda_function_arn                 = module.lambda.lambda_function_arn
  log_group_name                      = aws_cloudwatch_log_group.lambda_logs.name
  dynamodb_registry_table_name        = module.dynamodb.service_registry_table_name
  dynamodb_approved_services_table_name = module.dynamodb.approved_services_table_name
  eventbridge_rule_name               = module.events.event_rule_name
  sns_alert_topic_arn                 = module.notifications.alert_topic_arn
  aws_region                          = var.aws_region
  enable_cloudwatch_dashboard         = var.enable_cloudwatch_dashboard
  tags                                = var.tags
}
