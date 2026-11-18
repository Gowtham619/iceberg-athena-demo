environment = "prod"
region      = "ap-southeast-2"
owner       = "data-platform-team"
cost_center = "data-platform"

force_destroy           = false
bytes_scanned_cutoff    = 107374182400 # 100 GB
log_retention_days      = 365
noncurrent_version_days = 30

monthly_budget_usd = 500
alert_emails       = ["data-oncall@example.com"] # CHANGE ME

# Analysts: username => role ARN. Each may create tables only under sandbox/<username>/.
analysts = {
  # alice = "arn:aws:iam::111111111111:role/alice-analyst"
}

# Turn on after validating in a non-prod account (see docs/RUNBOOK.md#lake-formation)
enable_lake_formation = false
