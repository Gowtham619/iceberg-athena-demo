# OPTIONAL (enable_lake_formation = true): Lake Formation enforces data access.
# Validate in a non-prod account first. After the first apply run
# scripts/lf_lockdown.sh so the IAMAllowedPrincipals default grants stop bypassing LF.

locals {
  lf = var.enable_lake_formation ? { on = true } : {}

  lf_pipeline_principals = var.enable_lake_formation ? {
    sfn       = aws_iam_role.sfn.arn
    lambda    = aws_iam_role.ingest_lambda.arn
    glue      = aws_iam_role.glue.arn
    optimizer = aws_iam_role.optimizer.arn
  } : {}

  # pipeline principal x database
  lf_pipeline_db = {
    for pair in setproduct(keys(local.lf_pipeline_principals), local.databases) :
    "${pair[0]}-${pair[1]}" => { principal = local.lf_pipeline_principals[pair[0]], db = pair[1] }
  }
}

# Registration role: LF vends credentials with it, so it needs S3 + KMS (the SLR has no KMS access).
data "aws_iam_policy_document" "lf_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lakeformation.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lf_registration" {
  for_each           = local.lf
  name               = "${local.name}-lf-registration"
  assume_role_policy = data.aws_iam_policy_document.lf_assume.json
}

resource "aws_iam_role_policy" "lf_registration" {
  for_each = local.lf
  name     = "data-bucket"
  role     = aws_iam_role.lf_registration["on"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.data.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.data.arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.main.arn },
    ]
  })
}

resource "aws_lakeformation_data_lake_settings" "main" {
  for_each = local.lf
  admins = distinct(concat(
    [data.aws_iam_session_context.current.issuer_arn],
    var.lf_extra_admin_arns,
  ))
}

resource "aws_lakeformation_resource" "data" {
  for_each                = local.lf
  arn                     = aws_s3_bucket.data.arn
  role_arn                = aws_iam_role.lf_registration["on"].arn
  use_service_linked_role = false
  depends_on              = [aws_lakeformation_data_lake_settings.main, aws_iam_role_policy.lf_registration]
}

# ------------------------------------------------------- pipeline identities
resource "aws_lakeformation_permissions" "pipeline_db" {
  for_each    = local.lf_pipeline_db
  principal   = each.value.principal
  permissions = ["CREATE_TABLE", "ALTER", "DROP", "DESCRIBE"]
  database {
    name = each.value.db
  }
  depends_on = [aws_lakeformation_resource.data, aws_glue_catalog_database.main, aws_glue_catalog_database.sandbox]
}

resource "aws_lakeformation_permissions" "pipeline_tables" {
  for_each    = local.lf_pipeline_db
  principal   = each.value.principal
  permissions = ["ALL"]
  table {
    database_name = each.value.db
    wildcard      = true
  }
  depends_on = [aws_lakeformation_permissions.pipeline_db]
}

resource "aws_lakeformation_permissions" "pipeline_location" {
  for_each    = local.lf_pipeline_principals
  principal   = each.value
  permissions = ["DATA_LOCATION_ACCESS"]
  data_location {
    arn = aws_s3_bucket.data.arn
  }
  depends_on = [aws_lakeformation_resource.data]
}

# ------------------------------------------------------------------ analysts
locals {
  lf_analysts = var.enable_lake_formation ? var.analysts : {}
}

resource "aws_lakeformation_permissions" "analyst_main_db" {
  for_each    = local.lf_analysts
  principal   = each.value
  permissions = ["DESCRIBE"]
  database {
    name = local.db
  }
  depends_on = [aws_lakeformation_resource.data, aws_glue_catalog_database.main]
}

resource "aws_lakeformation_permissions" "analyst_main_tables" {
  for_each    = local.lf_analysts
  principal   = each.value
  permissions = ["SELECT", "DESCRIBE"] # curated data is read-only for analysts
  table {
    database_name = local.db
    wildcard      = true
  }
  depends_on = [aws_lakeformation_permissions.analyst_main_db]
}

resource "aws_lakeformation_permissions" "analyst_sandbox_db" {
  for_each    = local.lf_analysts
  principal   = each.value
  permissions = ["CREATE_TABLE", "ALTER", "DROP", "DESCRIBE"]
  database {
    name = local.sandbox_db
  }
  depends_on = [aws_lakeformation_resource.data, aws_glue_catalog_database.sandbox]
}

resource "aws_lakeformation_permissions" "analyst_sandbox_tables" {
  for_each    = local.lf_analysts
  principal   = each.value
  permissions = ["ALL"]
  table {
    database_name = local.sandbox_db
    wildcard      = true
  }
  depends_on = [aws_lakeformation_permissions.analyst_sandbox_db]
}

# Each analyst may only place table data under THEIR prefix - this is the enforced isolation.
resource "aws_lakeformation_permissions" "analyst_location" {
  for_each    = local.lf_analysts
  principal   = each.value
  permissions = ["DATA_LOCATION_ACCESS"]
  data_location {
    arn = "${aws_s3_bucket.data.arn}/sandbox/${each.key}"
  }
  depends_on = [aws_lakeformation_resource.data]
}
