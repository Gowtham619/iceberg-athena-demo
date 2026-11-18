terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile)

  # Partial configuration - supply per environment:
  #   terraform init -backend-config=envs/prod.backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.extra_tags, {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
    })
  }
}
