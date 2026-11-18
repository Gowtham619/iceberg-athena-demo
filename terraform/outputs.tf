output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "database" {
  value = aws_glue_catalog_database.main.name
}

output "sandbox_database" {
  value = aws_glue_catalog_database.sandbox.name
}

output "workgroup" {
  value = aws_athena_workgroup.main.name
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "ingest_state_machine_arn" {
  description = "Backfill: aws stepfunctions start-execution --state-machine-arn <this> --input '{\"dt\":\"YYYY-MM-DD\"}'"
  value       = aws_sfn_state_machine.ingest.arn
}

output "optimizers_function" {
  description = "Run now to enable managed optimizers on every Iceberg table: aws lambda invoke --function-name <this> out.json"
  value       = aws_lambda_function.optimizers.function_name
}

output "alerts_topic_arn" {
  description = "Subscribe PagerDuty / AWS Chatbot / Slack here"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "demo_env_exports" {
  description = "For the demo scripts (run_sql.py, generate_*.py)"
  value       = <<-EOT
    export BUCKET=${aws_s3_bucket.data.bucket}
    export DB=${aws_glue_catalog_database.main.name}
    export WORKGROUP=${aws_athena_workgroup.main.name}
    export AWS_REGION=${var.region}
  EOT
}
