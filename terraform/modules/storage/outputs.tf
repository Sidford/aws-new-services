output "baseline_bucket_id" {
  description = "Baseline snapshots S3 bucket ID"
  value       = aws_s3_bucket.baseline_snapshots.id
}

output "baseline_bucket_arn" {
  description = "Baseline snapshots S3 bucket ARN"
  value       = aws_s3_bucket.baseline_snapshots.arn
}
