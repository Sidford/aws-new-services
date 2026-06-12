output "lambda_role_arn" {
  description = "Lambda execution role ARN"
  value       = aws_iam_role.lambda_role.arn
}

output "lambda_role_name" {
  description = "Lambda execution role name"
  value       = aws_iam_role.lambda_role.name
}

output "lambda_role_id" {
  description = "Lambda execution role ID"
  value       = aws_iam_role.lambda_role.id
}
