# Three buckets: data (raw/iceberg/sandbox + system files), Athena results, access logs.

resource "aws_s3_bucket" "data" {
  bucket        = local.data_bucket
  force_destroy = false

  # Production data: removing this bucket must be a deliberate, manual code change.
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket" "results" {
  bucket        = local.results_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket" "logs" {
  bucket        = local.logs_bucket
  force_destroy = var.force_destroy
}

locals {
  buckets = {
    data    = aws_s3_bucket.data.id
    results = aws_s3_bucket.results.id
    logs    = aws_s3_bucket.logs.id
  }
}

resource "aws_s3_bucket_public_access_block" "all" {
  for_each                = local.buckets
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "all" {
  for_each = local.buckets
  bucket   = each.value
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kms" {
  for_each = { data = aws_s3_bucket.data.id, results = aws_s3_bucket.results.id }
  bucket   = each.value

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

# S3 server access log delivery does not support KMS - SSE-S3 is required here.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "data" {
  bucket        = aws_s3_bucket.data.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/data/"
  depends_on    = [aws_s3_bucket_policy.logs]
}

# ---------------------------------------------------------- bucket policies
data "aws_iam_policy_document" "tls_only" {
  for_each = local.buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["arn:${local.partition}:s3:::${each.value}", "arn:${local.partition}:s3:::${each.value}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "logs" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["logs"].json]

  statement {
    sid       = "S3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/s3-access/*"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.data.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  bucket     = aws_s3_bucket.data.id
  policy     = data.aws_iam_policy_document.tls_only["data"].json
  depends_on = [aws_s3_bucket_public_access_block.all]
}

resource "aws_s3_bucket_policy" "results" {
  bucket     = aws_s3_bucket.results.id
  policy     = data.aws_iam_policy_document.tls_only["results"].json
  depends_on = [aws_s3_bucket_public_access_block.all]
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs.json
  depends_on = [aws_s3_bucket_public_access_block.all]
}

# ---------------------------------------------------------------- lifecycle
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket     = aws_s3_bucket.data.id
  depends_on = [aws_s3_bucket_versioning.data]

  rule {
    id     = "noncurrent-and-multipart"
    status = "Enabled"
    filter {}

    # VACUUM deletes Iceberg files; versioning keeps a recovery window, then this expires them.
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  rule {
    id     = "expired-delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-results"
    status = "Enabled"
    filter {}
    expiration {
      days = var.athena_results_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_logs_days
    }
  }
}
