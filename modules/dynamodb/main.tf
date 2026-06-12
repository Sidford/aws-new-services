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
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_role_arn
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

# DynamoDB table for tracking services pending regional availability
resource "aws_dynamodb_table" "pending_regional_services" {
  name           = "aws-service-monitor-pending-regional"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "service_name"
  range_key      = "detected_at"

  attribute {
    name = "service_name"
    type = "S"
  }

  attribute {
    name = "detected_at"
    type = "S"
  }

  attribute {
    name = "region_name"
    type = "S"
  }

  attribute {
    name = "available_in_region"
    type = "N"
  }

  global_secondary_index {
    name            = "region-name-index"
    hash_key        = "region_name"
    range_key       = "available_in_region"
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
