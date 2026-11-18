# Managed Iceberg table optimizers (Glue Data Catalog): automatic compaction, snapshot retention and
# orphan-file deletion. Optimizers are per table, and tables are created at runtime (including analysts'),
# so a small Lambda enables them for every Iceberg table: on table creation (event) + daily reconcile.
# Verify automatic optimizers are available in your region before relying on this.

resource "aws_iam_role" "optimizer" {
  name               = "${local.name}-glue-optimizer"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy" "optimizer" {
  name   = "table-access"
  role   = aws_iam_role.optimizer.id
  policy = data.aws_iam_policy_document.pipeline_access.json # S3 + KMS + Glue get/update table
}

data "archive_file" "optimizers" {
  type        = "zip"
  source_file = "${path.module}/lambda/optimizers.py"
  output_path = "${path.module}/.build/optimizers.zip"
}

resource "aws_iam_role" "optimizers_lambda" {
  name               = "${local.name}-optimizers-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "optimizers_lambda" {
  name = "enable-optimizers"
  role = aws_iam_role.optimizers_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetTable", "glue:GetTables",
          "glue:GetTableOptimizer", "glue:BatchGetTableOptimizer", "glue:CreateTableOptimizer", "glue:UpdateTableOptimizer",
        ]
        Resource = local.glue_resources
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.optimizer.arn
        Condition = { StringEquals = { "iam:PassedToService" = "glue.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "optimizers_lambda_logs" {
  role       = aws_iam_role.optimizers_lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "optimizers" {
  name              = "/aws/lambda/${local.name}-enable-optimizers"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "optimizers" {
  function_name    = "${local.name}-enable-optimizers"
  role             = aws_iam_role.optimizers_lambda.arn
  runtime          = "python3.12"
  handler          = "optimizers.handler"
  filename         = data.archive_file.optimizers.output_path
  source_code_hash = data.archive_file.optimizers.output_base64sha256
  timeout          = 300
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      DATABASES                = join(",", local.databases)
      OPTIMIZER_ROLE_ARN       = aws_iam_role.optimizer.arn
      SNAPSHOT_RETENTION_DAYS  = tostring(var.snapshot_retention_days)
      ORPHAN_RETENTION_DAYS    = tostring(var.orphan_file_retention_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.optimizers, aws_iam_role_policy_attachment.optimizers_lambda_logs]
}

# Trigger 1: a table was created in one of our databases
resource "aws_cloudwatch_event_rule" "table_created" {
  name = "${local.name}-table-created"
  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Data Catalog Table State Change"]
    detail = {
      databaseName = local.databases
      typeOfChange = ["CreateTable"]
    }
  })
}

resource "aws_cloudwatch_event_target" "table_created" {
  rule = aws_cloudwatch_event_rule.table_created.name
  arn  = aws_lambda_function.optimizers.arn
}

resource "aws_lambda_permission" "table_created" {
  statement_id  = "AllowEventBridgeTableCreated"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.optimizers.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.table_created.arn
}

# Trigger 2: daily reconcile for anything missed
resource "aws_cloudwatch_event_rule" "optimizer_reconcile" {
  name                = "${local.name}-optimizer-reconcile"
  schedule_expression = var.optimizer_reconcile_schedule
}

resource "aws_cloudwatch_event_target" "optimizer_reconcile" {
  rule = aws_cloudwatch_event_rule.optimizer_reconcile.name
  arn  = aws_lambda_function.optimizers.arn
}

resource "aws_lambda_permission" "optimizer_reconcile" {
  statement_id  = "AllowEventBridgeReconcile"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.optimizers.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.optimizer_reconcile.arn
}
