# Values come from `terraform output` in ../bootstrap
bucket       = "gowtham-tfstate-111111111111"
key          = "iceberg-athena/prod/terraform.tfstate"
region       = "ap-southeast-2"
encrypt      = true
use_lockfile = true
