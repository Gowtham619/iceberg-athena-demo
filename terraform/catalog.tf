resource "aws_glue_catalog_database" "main" {
  name        = local.db
  description = "Curated + raw tables (${var.environment})"
}

resource "aws_glue_catalog_database" "sandbox" {
  name        = local.sandbox_db
  description = "Self-service: analysts create tables here (${var.environment})"
}

resource "aws_athena_workgroup" "main" {
  name          = local.name
  force_destroy = var.force_destroy

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.results.bucket}/athena/"
      expected_bucket_owner = local.account_id

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.main.arn
      }
    }
  }
}
