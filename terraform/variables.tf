# ------------------------------------------------------------------ identity
variable "project" {
  type    = string
  default = "iceberg-athena"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner" {
  description = "Team/person owning this stack (tag)"
  type        = string
}

variable "cost_center" {
  type    = string
  default = "data-platform"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

variable "database_name" {
  description = "Base name of the Glue database; environment is appended (e.g. lakehouse_prod)"
  type        = string
  default     = "lakehouse"
}

# --------------------------------------------------------------- protection
variable "force_destroy" {
  description = "Allow buckets (except the data bucket, which is prevent_destroy) to be deleted while non-empty. Keep false outside dev."
  type        = bool
  default     = false
}

variable "kms_deletion_window_days" {
  type    = number
  default = 30
}

# ---------------------------------------------------------------- retention
variable "noncurrent_version_days" {
  description = "Days to keep non-current object versions of the data bucket (limits cost of versioning + VACUUM)"
  type        = number
  default     = 30
}

variable "athena_results_days" {
  type    = number
  default = 30
}

variable "access_logs_days" {
  type    = number
  default = 365
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention"
  type        = number
  default     = 90
}

# ------------------------------------------------------------------- athena
variable "bytes_scanned_cutoff" {
  description = "Per-query scan limit in bytes (default 100 GB)"
  type        = number
  default     = 107374182400
}

# --------------------------------------------------------------- automation
variable "catchup_schedule" {
  description = "EventBridge cron (UTC) for the daily SLA check/catch-up. It loads yesterday if no event arrived and ALERTS if the data never did. Set it to your SLA time."
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "ready_marker_name" {
  description = "Marker file the upstream writes LAST into each day's folder (e.g. raw/orders_daily/dt=2026-11-17/_SUCCESS). Its arrival starts the load. Pipelines set ready_marker to this name."
  type        = string
  default     = "_SUCCESS"
}

variable "arrival_wait_minutes" {
  description = "Manual runs only: minutes between checks while waiting for the day's source files"
  type        = number
  default     = 15
}

variable "arrival_max_attempts" {
  description = "Manual runs only: checks before giving up (default 15 min * 16 = 4h). Event and catch-up runs do not wait."
  type        = number
  default     = 16
}

# -------------------------------------------------------------- alerts/cost
variable "alert_emails" {
  description = "Emails subscribed to the alerts SNS topic (each must confirm). Add PagerDuty/Chatbot to the topic separately."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for resources tagged Project=<project>. 0 disables. Requires the Project cost-allocation tag to be activated."
  type        = number
  default     = 0
}

# ------------------------------------------------------------ access control
variable "analysts" {
  description = "Self-service users: username => IAM role ARN. Each gets their own sandbox prefix sandbox/<username>/."
  type        = map(string)
  default     = {}
}

variable "enable_lake_formation" {
  description = "Enforce access with Lake Formation (registered data location + grants). Validate in a non-prod account first; see docs/RUNBOOK.md."
  type        = bool
  default     = false
}

variable "lf_extra_admin_arns" {
  description = "Extra Lake Formation administrators (the Terraform deploy role is always added)"
  type        = list(string)
  default     = []
}

# ------------------------------------------------------- large daily merges
variable "glue_merge_worker_type" {
  description = "Glue worker type for the Spark merge job (G.1X = 4 vCPU/16 GB, G.2X = 8 vCPU/32 GB)"
  type        = string
  default     = "G.1X"
}

variable "glue_merge_workers" {
  description = "Max workers for the Spark merge job (auto-scaling). 10 G.1X workers is a sensible start for ~10 GB/day."
  type        = number
  default     = 10
}

# --------------------------------------------------- managed table optimizers
variable "snapshot_retention_days" {
  description = "Iceberg snapshots older than this are expired automatically (this is also your time-travel window)"
  type        = number
  default     = 7
}

variable "orphan_file_retention_days" {
  type    = number
  default = 3
}

variable "optimizer_reconcile_schedule" {
  description = "EventBridge cron (UTC): daily pass that enables managed optimizers on any Iceberg table that lacks them"
  type        = string
  default     = "cron(30 5 * * ? *)"
}
