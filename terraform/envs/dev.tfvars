environment = "dev"
region      = "ap-southeast-2"
owner       = "data-platform-team"

force_destroy           = true
bytes_scanned_cutoff    = 10737418240 # 10 GB
log_retention_days      = 30
noncurrent_version_days = 7

# alert_emails = ["you@example.com"]
# analysts     = { alice = "arn:aws:iam::111111111111:role/alice-analyst" }
