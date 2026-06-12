output "lambda_role_arn" {
  description = "Lambda execution role ARN"
  value       = var.existing_role_id != "" ? data.aws_iam_role.existing[0].arn : aws_iam_role.lambda_role[0].arn
}

output "lambda_role_name" {
  description = "Lambda execution role name"
  value       = var.existing_role_id != "" ? data.aws_iam_role.existing[0].name : aws_iam_role.lambda_role[0].name
}

output "lambda_role_id" {
  description = "Lambda execution role ID"
  value       = local.lambda_role_id
}
