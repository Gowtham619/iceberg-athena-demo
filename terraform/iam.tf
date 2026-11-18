# --------------------------------------------------------------------------
# Shared permissions for the pipeline identities (ingest Lambda, Step Functions - which runs
# Athena merges - the Glue Spark merge job and the table-optimizer role).
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "pipeline_access" {
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.data.arn, aws_s3_bucket.results.arn]
  }
  statement {
    sid       = "DataObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.data.arn}/*", "${aws_s3_bucket.results.arn}/*"]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.main.arn]
  }
  statement {
    sid = "Athena"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution",
      "athena:GetQueryResults", "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.main.arn]
  }
  statement {
    sid       = "AthenaCatalog"
    actions   = ["athena:GetDataCatalog"]
    resources = ["arn:${local.partition}:athena:${var.region}:${local.account_id}:datacatalog/*"]
  }
  statement {
    sid = "Glue"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:UpdateTable",
      "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
    ]
    resources = local.glue_resources
  }
  statement {
    sid       = "LakeFormationData"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }
}

# ------------------------------------------------------------ ingest Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest_lambda" {
  name               = "${local.name}-ingest-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "ingest_lambda" {
  name   = "pipeline-access"
  role   = aws_iam_role.ingest_lambda.id
  policy = data.aws_iam_policy_document.pipeline_access.json
}

resource "aws_iam_role_policy" "ingest_lambda_metrics" {
  name = "metrics"
  role = aws_iam_role.ingest_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = local.metric_namespace } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ingest_lambda_logs" {
  role       = aws_iam_role.ingest_lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ------------------------------------------------------------ Step Functions
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-ingest-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn_pipeline" {
  name   = "pipeline-access" # Athena queries started by Step Functions run as this role
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.pipeline_access.json
}

resource "aws_iam_role_policy" "sfn_extra" {
  name = "invoke-and-logs"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.ingest.arn, "${aws_lambda_function.ingest.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = aws_glue_job.merge.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

# ------------------------------------------------- Glue Spark merge job role
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${local.name}-glue-merge"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy" "glue_pipeline" {
  name   = "pipeline-access"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.pipeline_access.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# -------------------------------------------------- analysts (self-service)
# Without Lake Formation: S3 prefix scoping enforces isolation (read shared data,
# write ONLY sandbox/<username>/). With Lake Formation: LF grants do the data
# access; IAM keeps the API-level guardrails (sandbox-only table writes).
data "aws_iam_policy_document" "analyst" {
  for_each = var.analysts

  statement {
    sid       = "ResultsBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.results.arn}/athena/*"]
  }
  statement {
    sid       = "ResultsBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.results.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.main.arn]
  }
  statement {
    sid = "Athena"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution",
      "athena:BatchGetQueryExecution", "athena:ListQueryExecutions", "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.main.arn]
  }
  statement {
    sid = "GlueRead"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
    ]
    resources = local.glue_resources
  }
  statement {
    sid     = "GlueWriteSandboxOnly"
    actions = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
    resources = [
      "${local.glue_prefix}:catalog",
      "${local.glue_prefix}:database/${local.sandbox_db}",
      "${local.glue_prefix}:table/${local.sandbox_db}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.enable_lake_formation ? [1] : []
    content {
      sid       = "LakeFormationData"
      actions   = ["lakeformation:GetDataAccess"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_lake_formation ? [] : [1]
    content {
      sid       = "ListSharedPrefixes"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [aws_s3_bucket.data.arn]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["", "raw/*", "iceberg/*", "sandbox/*", "raw", "iceberg", "sandbox"]
      }
    }
  }
  dynamic "statement" {
    for_each = var.enable_lake_formation ? [] : [1]
    content {
      sid       = "ReadSharedData"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.data.arn}/raw/*", "${aws_s3_bucket.data.arn}/iceberg/*", "${aws_s3_bucket.data.arn}/sandbox/*"]
    }
  }
  dynamic "statement" {
    for_each = var.enable_lake_formation ? [] : [1]
    content {
      sid       = "WriteOwnSandbox"
      actions   = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      resources = ["${aws_s3_bucket.data.arn}/sandbox/${each.key}/*"]
    }
  }
}

resource "aws_iam_policy" "analyst" {
  for_each    = var.analysts
  name        = "${local.name}-analyst-${each.key}"
  description = "Self-service Athena access for ${each.key}; may create tables in ${local.sandbox_db} under sandbox/${each.key}/"
  policy      = data.aws_iam_policy_document.analyst[each.key].json
}

resource "aws_iam_role_policy_attachment" "analyst" {
  for_each   = var.analysts
  role       = local.analyst_role_names[each.key]
  policy_arn = aws_iam_policy.analyst[each.key].arn
}
