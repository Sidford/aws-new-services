# S3 bucket for immutable baseline snapshots (T004 mitigation)
resource "aws_s3_bucket" "baseline_snapshots" {
  bucket = "service-monitor-baseline-${var.aws_account_id}-${var.aws_region}"

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "baseline_snapshots" {
  depends_on = [aws_s3_bucket_versioning.baseline_snapshots]

  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 90  # 90-day retention for immutability
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "baseline_snapshots" {
  bucket = aws_s3_bucket.baseline_snapshots.id

  rule {
    id     = "delete_old_snapshots"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
