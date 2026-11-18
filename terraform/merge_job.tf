# Glue Spark job used by pipelines with `engine: glue` (large daily upserts); started by Step Functions.
resource "aws_s3_object" "spark_merge_script" {
  bucket     = aws_s3_bucket.data.id
  key        = "_system/scripts/spark_merge.py"
  source     = "${path.module}/glue/spark_merge.py"
  etag       = filemd5("${path.module}/glue/spark_merge.py")
  depends_on = [aws_s3_bucket_server_side_encryption_configuration.kms]
}

resource "aws_glue_job" "merge" {
  name              = "${local.name}-spark-merge"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "5.0"
  worker_type       = var.glue_merge_worker_type
  number_of_workers = var.glue_merge_workers # with auto-scaling this is the MAXIMUM
  timeout           = 120                    # minutes
  max_retries       = 0                      # Step Functions decides what to do on failure

  execution_property {
    max_concurrent_runs = 2
  }

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.data.bucket}/${aws_s3_object.spark_merge_script.key}"
  }

  default_arguments = {
    "--datalake-formats"                 = "iceberg"
    "--enable-auto-scaling"              = "true"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    # Register the Glue Data Catalog as an Iceberg catalog named glue_catalog
    "--conf" = join(" --conf ", [
      "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
      "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
      "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
      "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
      "spark.sql.catalog.glue_catalog.warehouse=s3://${aws_s3_bucket.data.bucket}/iceberg/",
    ])
  }
}
