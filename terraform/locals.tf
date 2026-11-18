data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  db         = "${var.database_name}_${var.environment}"
  sandbox_db = "${local.db}_sandbox"
  databases  = [local.db, local.sandbox_db]

  data_bucket    = "${local.name}-data-${local.account_id}"
  results_bucket = "${local.name}-athena-results-${local.account_id}"
  logs_bucket    = "${local.name}-logs-${local.account_id}"

  glue_prefix = "arn:${local.partition}:glue:${var.region}:${local.account_id}"
  glue_resources = flatten([
    "${local.glue_prefix}:catalog",
    [for d in local.databases : [
      "${local.glue_prefix}:database/${d}",
      "${local.glue_prefix}:table/${d}/*",
    ]],
  ])

  # One YAML file in ./pipelines = one daily pipeline.
  pipelines = {
    for f in fileset("${path.module}/pipelines", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(templatefile("${path.module}/pipelines/${f}", { db = local.db }))
  }
  pipelines_json = jsonencode([for k, v in local.pipelines : merge(v, { name = k })])

  analyst_role_names = {
    for u, arn in var.analysts : u => element(split("/", arn), length(split("/", arn)) - 1)
  }
}
