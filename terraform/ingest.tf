# Event-driven ingest:
#   upstream writes files, then a marker (<ready_marker_name>) last
#   -> S3 event (EventBridge) -> Step Functions -> check files -> quality gate -> MERGE (Athena | Glue Spark)
# A daily catch-up run is the SLA safety net: it loads yesterday if an event was missed and ALERTS if data never arrived.
# A failing execution raises an alert (monitoring.tf).

locals {
  metric_namespace = "${var.project}/Pipelines"
  ingest_fn_name   = "${local.name}-ingest-tasks"
  sfn_name         = "${local.name}-daily-ingest"

  lambda_retry = [{
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
    IntervalSeconds = 2
    MaxAttempts     = 4
    BackoffRate     = 2
  }]

  to_failed = [{
    ErrorEquals = ["States.ALL"]
    ResultPath  = "$.error"
    Next        = "PipelineFailed"
  }]

  sfn_definition = {
    Comment = "Ingest (${var.environment}): check files -> quality gate -> merge"
    StartAt = "Plan"
    States = {
      Plan = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.ingest.arn
          Payload      = { action = "plan", "event.$" = "$" }
        }
        OutputPath = "$.Payload"
        Retry      = local.lambda_retry
        Next       = "Pipelines"
      }

      Pipelines = {
        Type           = "Map"
        ItemsPath      = "$.items"
        MaxConcurrency = 2
        ResultPath     = "$.results"
        Next           = "Finalize"
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "CheckArrival"
          States = {
            CheckArrival = {
              Type     = "Task"
              Resource = "arn:${local.partition}:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.ingest.arn
                Payload      = { action = "check_arrival", "item.$" = "$" }
              }
              OutputPath = "$.Payload"
              Retry      = local.lambda_retry
              Catch      = local.to_failed
              Next       = "IsReady"
            }
            IsReady = {
              Type = "Choice"
              Choices = [
                { Variable = "$.ready", BooleanEquals = true, Next = "Validate" },
                { Variable = "$.attempt", NumericGreaterThanEqualsPath = "$.max_attempts", Next = "ArrivalTimeout" },
              ]
              Default = "WaitForData"
            }
            WaitForData = {
              Type    = "Wait"
              Seconds = var.arrival_wait_minutes * 60
              Next    = "CheckArrival"
            }
            ArrivalTimeout = {
              Type = "Pass"
              Parameters = {
                "name.$" = "$.name"
                status   = "FAILED"
                error    = "Source data did not arrive in time"
              }
              End = true
            }
            Validate = {
              Type     = "Task"
              Resource = "arn:${local.partition}:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.ingest.arn
                Payload      = { action = "validate", "item.$" = "$" }
              }
              ResultPath = null # keep the item; a DataQualityError goes to Catch
              Retry      = local.lambda_retry
              Catch      = local.to_failed
              Next       = "ChooseEngine"
            }
            ChooseEngine = {
              Type    = "Choice"
              Choices = [{ Variable = "$.engine", StringEquals = "glue", Next = "MergeGlue" }]
              Default = "MergeAthena"
            }
            MergeAthena = {
              Type     = "Task"
              Resource = "arn:${local.partition}:states:::athena:startQueryExecution.sync"
              Parameters = {
                "QueryString.$" = "$.merge_sql"
                WorkGroup       = aws_athena_workgroup.main.name
              }
              ResultPath     = null
              TimeoutSeconds = 1800 # Athena DML hard-stops at 30 min by default
              Catch          = local.to_failed
              Next           = "PipelineSucceeded"
            }
            MergeGlue = {
              Type     = "Task"
              Resource = "arn:${local.partition}:states:::glue:startJobRun.sync"
              Parameters = {
                JobName = aws_glue_job.merge.name
                Arguments = {
                  "--SOURCE_PATH.$"   = "$.source_uri"
                  "--SOURCE_FORMAT.$" = "$.source_format"
                  "--MERGE_SQL_URI.$" = "$.merge_sql_uri"
                }
              }
              ResultPath     = null
              TimeoutSeconds = 7200
              Catch          = local.to_failed
              Next           = "PipelineSucceeded"
            }
            PipelineSucceeded = {
              Type       = "Pass"
              Parameters = { "name.$" = "$.name", status = "SUCCEEDED" }
              End        = true
            }
            PipelineFailed = {
              Type = "Pass"
              Parameters = {
                "name.$"  = "$.name"
                status    = "FAILED"
                "error.$" = "States.JsonToString($.error)"
              }
              End = true
            }
          }
        }
      }

      Finalize = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.ingest.arn
          Payload      = { action = "finalize", "results.$" = "$.results", "dt.$" = "$.dt" }
        }
        OutputPath = "$.Payload"
        Retry      = local.lambda_retry
        End        = true
      }
    }
  }
}

# ------------------------------------------------------------------ config
resource "aws_s3_object" "pipelines" {
  bucket       = aws_s3_bucket.data.id
  key          = "_system/config/pipelines.json"
  content      = local.pipelines_json
  content_type = "application/json"
  etag         = md5(local.pipelines_json)
  depends_on   = [aws_s3_bucket_server_side_encryption_configuration.kms]
}

# ------------------------------------------------------------------ Lambda
data "archive_file" "ingest" {
  type        = "zip"
  source_file = "${path.module}/lambda/ingest_tasks.py"
  output_path = "${path.module}/.build/ingest_tasks.zip"
}

resource "aws_cloudwatch_log_group" "ingest_lambda" {
  name              = "/aws/lambda/${local.ingest_fn_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "ingest" {
  function_name    = local.ingest_fn_name
  role             = aws_iam_role.ingest_lambda.arn
  runtime          = "python3.12"
  handler          = "ingest_tasks.handler"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  timeout          = 300
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      DATA_BUCKET          = aws_s3_bucket.data.bucket
      WORKGROUP            = aws_athena_workgroup.main.name
      CONFIG_KEY           = "_system/config/pipelines.json"
      METRIC_NAMESPACE     = local.metric_namespace
      ENVIRONMENT          = var.environment
      ARRIVAL_MAX_ATTEMPTS = tostring(var.arrival_max_attempts)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest_lambda, aws_iam_role_policy_attachment.ingest_lambda_logs]
}

# ---------------------------------------------------------- state machine
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.sfn_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sfn_state_machine" "ingest" {
  name       = local.sfn_name
  role_arn   = aws_iam_role.sfn.arn
  definition = jsonencode(local.sfn_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  depends_on = [aws_iam_role_policy.sfn_extra, aws_iam_role_policy.sfn_pipeline]
}

# ------------------------------------------------------------------ triggers
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_start_sfn" {
  name               = "${local.name}-events-start-ingest"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "events_start_sfn" {
  name = "start-execution"
  role = aws_iam_role.events_start_sfn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.ingest.arn }]
  })
}

# 1) Event: S3 -> EventBridge when the marker file lands
resource "aws_s3_bucket_notification" "data" {
  bucket      = aws_s3_bucket.data.id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "marker" {
  name        = "${local.sfn_name}-marker"
  description = "Upstream wrote ${var.ready_marker_name}: start the load for that pipeline/day"
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.data.bucket] }
      object = { key = [{ suffix = "/${var.ready_marker_name}" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "marker" {
  rule     = aws_cloudwatch_event_rule.marker.name
  arn      = aws_sfn_state_machine.ingest.arn
  role_arn = aws_iam_role.events_start_sfn.arn

  input_transformer {
    input_paths    = { key = "$.detail.object.key" }
    input_template = "{\"trigger\":\"s3\",\"key\":\"<key>\"}"
  }

  depends_on = [aws_s3_bucket_notification.data]
}

# 2) Safety net / SLA check: load anything missed, alert if yesterday's data never arrived
resource "aws_cloudwatch_event_rule" "catchup" {
  name                = "${local.sfn_name}-catchup"
  description         = "Daily SLA check and catch-up"
  schedule_expression = var.catchup_schedule
}

resource "aws_cloudwatch_event_target" "catchup" {
  rule     = aws_cloudwatch_event_rule.catchup.name
  arn      = aws_sfn_state_machine.ingest.arn
  role_arn = aws_iam_role.events_start_sfn.arn
  input    = jsonencode({ trigger = "catchup" })
}
