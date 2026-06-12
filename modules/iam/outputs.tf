output "lambda_role_arn" {
  description = "Lambda execution role ARN"
  value       = data.aws_iam_role.existing[0].arn
}

output "lambda_role_name" {
  description = "Lambda execution role name"
  value       = data.aws_iam_role.existing[0].name
}

output "lambda_role_id" {
  description = "Lambda execution role ID"
  value       = data.aws_iam_role.existing[0].id
}
