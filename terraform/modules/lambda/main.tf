# Archive the Lambda function code
data "archive_file" "lambda_code" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda"
  output_path = "${path.module}/../../lambda.zip"
}

# Lambda function for AWS service monitoring
resource "aws_lambda_function" "service_monitor" {
  filename         = data.archive_file.lambda_code.output_path
  function_name    = var.function_name
  role             = var.role_arn
  handler          = "index.lambda_handler"
  source_code_hash = data.archive_file.lambda_code.output_base64sha256
  timeout          = 300
  runtime          = "python3.11"

  environment {
    variables = {
      DYNAMODB_TABLE                   = var.dynamodb_table_names.service_registry
      APPROVED_SERVICES_TABLE          = var.dynamodb_table_names.approved_services
      PENDING_REGIONAL_SERVICES_TABLE  = var.dynamodb_table_names.pending_regional_services
      SCP_NAME                         = var.scp_name
      SCP_SID                          = var.scp_sid
      EMAIL_RECIPIENTS                 = jsonencode(var.email_recipients)
      SENDER_EMAIL                     = var.sender_email
      REQUIRE_APPROVAL                 = var.require_scp_approval ? "true" : "false"
      MANAGE_SCP_POLICY                = var.manage_scp_policy ? "true" : "false"
      BASELINE_SNAPSHOT_BUCKET         = var.s3_bucket_name
      ALERT_TOPIC_ARN                  = var.sns_alert_topic_arn
      ENABLE_SERVICE_APPROVAL_WORKFLOW = var.enable_service_approval_workflow ? "true" : "false"
      APPROVED_SERVICES_LIST           = jsonencode(var.approved_services)
      APPROVAL_RECIPIENTS              = jsonencode(length(var.approval_recipients) > 0 ? var.approval_recipients : var.email_recipients)
      ENABLE_REGIONAL_MONITORING       = "true"
      MONITORED_REGION                 = var.aws_region
    }
  }

  tags = var.tags
}
