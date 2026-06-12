output "kms_key_id" {
  description = "KMS key ID for DynamoDB encryption"
  value       = aws_kms_key.dynamodb.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN for DynamoDB encryption"
  value       = aws_kms_key.dynamodb.arn
}

output "service_registry_table_name" {
  description = "Service registry table name"
  value       = aws_dynamodb_table.service_registry.name
}

output "service_registry_table_arn" {
  description = "Service registry table ARN"
  value       = aws_dynamodb_table.service_registry.arn
}

output "approved_services_table_name" {
  description = "Approved services table name"
  value       = aws_dynamodb_table.approved_services.name
}

output "approved_services_table_arn" {
  description = "Approved services table ARN"
  value       = aws_dynamodb_table.approved_services.arn
}

output "pending_regional_services_table_name" {
  description = "Pending regional services table name"
  value       = aws_dynamodb_table.pending_regional_services.name
}

output "pending_regional_services_table_arn" {
  description = "Pending regional services table ARN"
  value       = aws_dynamodb_table.pending_regional_services.arn
}

output "pending_regional_gsi_name" {
  description = "Global Secondary Index name for pending regional services"
  value       = "RegionalIndex"
}

output "pending_regional_gsi_arn" {
  description = "Global Secondary Index ARN for pending regional services"
  value       = "${aws_dynamodb_table.pending_regional_services.arn}/index/region-name-index"
}
