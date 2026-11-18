# One-time bootstrap (run with local state, then keep/back up bootstrap/terraform.tfstate):
#   - S3 bucket for Terraform state (versioned, encrypted, TLS-only; native S3 locking)
#   - GitHub Actions OIDC provider + deploy/plan roles (no long-lived AWS keys in CI)
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "iceberg-athena", ManagedBy = "terraform", Owner = var.owner, Purpose = "tf-bootstrap" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner" {
  type = string
}

variable "state_bucket_name" {
  description = "Globally unique name, e.g. mycompany-tfstate-<account-id>"
  type        = string
}

variable "github_repo" {
  description = "org/repo allowed to assume the CI roles"
  type        = string
}

variable "environments" {
  type    = list(string)
  default = ["dev", "prod"]
}

variable "create_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this account"
  type        = bool
  default     = true
}

variable "deploy_policy_arns" {
  description = "Policies for the APPLY roles. Administrator is the simple default - scope it down for prod (IAM, KMS, S3, Glue, Athena, Lambda, States, Events, SNS, CloudWatch, Budgets, LakeFormation)."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------ state bucket
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_versioning.state]
  rule {
    id     = "old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
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

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ----------------------------------------------------------- GitHub OIDC
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # ignored by AWS for GitHub, but required by the API
}

locals {
  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust_apply" {
  for_each = toset(var.environments)
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${each.key}"] # GitHub Environment (add approvers on prod)
    }
  }
}

resource "aws_iam_role" "apply" {
  for_each             = toset(var.environments)
  name                 = "gh-iceberg-apply-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply" {
  for_each = {
    for pair in setproduct(var.environments, var.deploy_policy_arns) : "${pair[0]}|${pair[1]}" => { env = pair[0], arn = pair[1] }
  }
  role       = aws_iam_role.apply[each.value.env].name
  policy_arn = each.value.arn
}

data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "gh-iceberg-plan"
  assume_role_policy = data.aws_iam_policy_document.trust_plan.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # includes the .tflock lock file
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy" "apply_state" {
  for_each = toset(var.environments)
  name     = "state-access"
  role     = aws_iam_role.apply[each.key].id
  policy   = data.aws_iam_policy_document.state_access.json
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "apply_role_arns" {
  value = { for e, r in aws_iam_role.apply : e => r.arn }
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}
