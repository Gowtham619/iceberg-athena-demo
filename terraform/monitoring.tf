# Alerts (SNS), failure events, freshness alarms, dashboard, budget.

resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.main.arn
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AllowPublishFromAccountServices"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ------------------------------------------------------ failure notifications
resource "aws_cloudwatch_event_rule" "ingest_failed" {
  name = "${local.name}-ingest-failed"
  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      stateMachineArn = [aws_sfn_state_machine.ingest.arn]
      status          = ["FAILED", "TIMED_OUT", "ABORTED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ingest_failed" {
  rule = aws_cloudwatch_event_rule.ingest_failed.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      status = "$.detail.status"
      exec   = "$.detail.name"
      error  = "$.detail.error"
      cause  = "$.detail.cause"
    }
    input_template = "\"[${var.environment}] Ingest <status>: execution <exec>. error=<error> cause=<cause>. Open the execution in Step Functions for per-pipeline results.\""
  }
}

# ------------------------------------------------------------------- alarms
resource "aws_cloudwatch_metric_alarm" "ingest_executions_failed" {
  alarm_name          = "${local.name}-ingest-executions-failed"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.ingest.arn }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = {
    ingest     = aws_lambda_function.ingest.function_name
    optimizers = aws_lambda_function.optimizers.function_name
  }

  alarm_name          = "${each.value}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Freshness: no successful load for a pipeline in 36h (six consecutive empty 6h windows).
resource "aws_cloudwatch_metric_alarm" "freshness" {
  for_each = toset(keys(local.pipelines))

  alarm_name          = "${local.name}-${each.key}-stale"
  alarm_description   = "No successful ${each.key} load in 36h"
  namespace           = local.metric_namespace
  metric_name         = "SuccessfulLoads"
  dimensions          = { Pipeline = each.key, Environment = var.environment }
  statistic           = "Sum"
  period              = 21600
  evaluation_periods  = 6
  datapoints_to_alarm = 6
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------- dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Ingest executions", region = var.region, stat = "Sum", period = 3600
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.ingest.arn],
            [".", "ExecutionsFailed", ".", "."],
            [".", "ExecutionsTimedOut", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Source rows per daily load", region = var.region, stat = "Maximum", period = 86400
          metrics = [for p in keys(local.pipelines) : [local.metric_namespace, "SourceRows", "Pipeline", p, "Environment", var.environment]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "Successful loads (1 = loaded)", region = var.region, stat = "Sum", period = 86400
          metrics = [for p in keys(local.pipelines) : [local.metric_namespace, "SuccessfulLoads", "Pipeline", p, "Environment", var.environment]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Athena data scanned (bytes)", region = var.region, stat = "Sum", period = 3600
          metrics = [["AWS/Athena", "ProcessedBytes", "WorkGroup", aws_athena_workgroup.main.name]]
        }
      },
    ]
  })
}

# ------------------------------------------------------------------- budget
resource "aws_budgets_budget" "monthly" {
  count        = var.monthly_budget_usd > 0 ? 1 : 0
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_emails
  }
}
