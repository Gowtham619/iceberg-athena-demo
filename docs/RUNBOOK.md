# Runbook

## First-time setup
1. **Bootstrap** (once per AWS account): `cd bootstrap && cp terraform.tfvars.example terraform.tfvars` (edit) `&& terraform init && terraform apply`.
   Back up `bootstrap/terraform.tfstate` (or migrate it into the state bucket).
2. Put the state bucket name into `terraform/envs/*.backend.hcl`.
3. In GitHub: create Environments `dev` and `prod` (add **required reviewers** to `prod`). Set variables:
   `AWS_PLAN_ROLE_ARN_DEV/PROD` (repo level, = `plan_role_arn`) and `AWS_APPLY_ROLE_ARN` (per environment, = `apply_role_arns[env]`).
4. Deploy: `cd terraform && terraform init -backend-config=envs/dev.backend.hcl && terraform apply -var-file=envs/dev.tfvars`
   (afterwards CI does this on merge to `main`: dev first, then prod after approval).
5. Create tables once (DDL is not Terraform-managed): `export $(terraform output -raw demo_env_exports | xargs)`
   then `python run_sql.py sql/03_create_iceberg_ddl_insert.sql` and `sql/07_raw_daily_partitioned.sql`.
   (`sql/` files contain `DROP TABLE` - fine for dev, **do not run against prod data**; write non-destructive DDL for prod or use dbt-athena.)
6. Confirm the SNS e-mail subscriptions.

## Upstream contract (what the data provider must do)
1. Write the day's files under the pipeline's prefix, e.g. `raw/orders_daily/dt=2026-11-17/` (Parquet preferred).
2. **Only after every file is complete**, write an empty object named `_SUCCESS` in that folder. Its arrival starts the load.
3. Corrections for an old day: rewrite the files and write `_SUCCESS` again - the load re-runs (MERGE is idempotent).
Pipelines need `ready_marker` set to the marker name (`var.ready_marker_name`, default `_SUCCESS`); a pipeline with no marker is only
loaded by the 06:00 UTC catch-up run (`catchup_schedule`) or manually. Set the catch-up time to your delivery SLA.

## Daily operations
| Task | How |
|---|---|
| Normal load | automatic: the upstream writes the day's files, then `_SUCCESS` last; the S3 event starts the load |
| Backfill / re-run a date | `aws stepfunctions start-execution --state-machine-arn <ingest_state_machine_arn> --input '{"dt":"2026-11-10"}'` (MERGE is idempotent; manual runs wait for files). One pipeline: add `"pipeline":"orders"` |
| Add a pipeline/table | add `terraform/pipelines/<name>.yaml` (source, checks, MERGE) and merge the PR |
| Enable optimizers now | `aws lambda invoke --function-name <optimizers_function> out.json` (also runs on every table creation + daily) |
| Onboard an analyst | add `username = "<role arn>"` to `analysts` in `envs/<env>.tfvars`; they create tables only under `sandbox/<username>/` |
| Time-travel retention | `VACUUM` keeps 5 days of snapshots by default; set `vacuum_max_snapshot_age_seconds` table property if you need longer |

## Alert -> response
- **Ingest FAILED**: open the execution in Step Functions; the `Finalize` error lists failed pipelines.
  - `DataQualityError`: too few rows / NULL keys / duplicate keys in the source partition -> fix upstream, re-run the date.
  - `Source data did not arrive in time` from the **06:00 catch-up run**: the upstream missed its SLA -> get the files + `_SUCCESS` delivered (the marker then starts the load itself).
  - Athena/Glue error in the merge step: check the query in the Athena console, or the Spark job run in Glue.
  - `DataQualityError`: source partition has too few rows / NULL keys / duplicate keys -> fix upstream, re-run the date.
  - `Source data did not arrive in time`: upstream is late (default max wait 4h) -> get the file delivered, re-run the date.
  - Athena error in `Merge`: check the query in the Athena console (workgroup = `<project>-<env>`).
- **`<pipeline>-stale` alarm**: no successful load for 36h - check the last executions.
- **Optimizer Lambda errors alarm**: see its CloudWatch log; usually a permissions or region-availability issue. Check table health under Glue -> Tables -> Table optimization.
- **Budget alert**: Athena data-scanned widget on the dashboard; look for un-partitioned scans.

## Separate AWS accounts per environment (recommended for prod)
Run `bootstrap/` once in each account (set `github_repo`; each account gets its own state bucket and CI roles), point
`envs/<env>.backend.hcl` at that account's state bucket, and set the GitHub variables per environment to that account's role ARNs.
Nothing else in `terraform/` changes - resource names already include the environment and account ID.
Use IAM Identity Center (SSO) for people (`aws sso login`); no long-lived access keys.

## Disaster recovery
- Data bucket is versioned (non-current versions kept `noncurrent_version_days`) and `prevent_destroy`. Accidentally deleted
  Iceberg files can be restored from versions; the KMS key has a 30-day deletion window and rotation.
- Iceberg time travel (`FOR TIMESTAMP AS OF`) rolls back logical mistakes within the snapshot retention.
- State bucket is versioned; restore a previous state version if needed.
- Everything else is recreated from code (`terraform apply`).

## Lake Formation
Off by default. To try it (non-prod account first):
1. `enable_lake_formation = true`, apply.
2. `scripts/lf_lockdown.sh <db> <db>_sandbox` to revoke the IAMAllowedPrincipals default grants.
3. Verify: an analyst can SELECT from curated tables, create a table under their own `sandbox/<user>/` prefix, and cannot write elsewhere.
For column/row-level rules, replace the wildcard `SELECT` grant (`analyst_main_tables`) with `table_with_columns` grants or data-cell filters.

## Accepted trade-offs / known limits
- Lambda and Glue run outside a VPC (they only call AWS APIs over TLS); add VPC endpoints + VPC config if policy requires.
- No cross-region replication of the data bucket.
- Event-driven loads rely on the upstream writing the `_SUCCESS` marker last; EventBridge delivery is at-least-once (loads are idempotent).
- Managed table optimizers must be available in your region (check before prod); the optimizer Lambda uses the Glue table-optimizer APIs and is the least-proven part along with Lake Formation.
- Table DDL/schema migrations are manual (consider dbt-athena or a migration step in CI).
- Apply roles default to AdministratorAccess in `bootstrap` - scope down before prod use.

## Large daily upserts (~10 GB/day, rows change)
- Set `engine: glue` in the pipeline YAML (see `terraform/pipelines/example_large_upsert.yaml.example`). Step Functions then starts the
  Spark job `<project>-<env>-spark-merge` and waits for it (no Athena 30-minute DML limit). Arrival wait, quality gate and alerts are unchanged.
- Small tables can stay on `engine: athena` (default).
- Land source files as **Parquet** (CSV works but is slow), and have the upstream write a `_SUCCESS` marker last (`ready_marker`).
- Tune `glue_merge_workers` / `glue_merge_worker_type` (default 10 x G.1X, auto-scaling). Watch the job's duration in Glue; raise workers before raising the timeout.
- If updates only touch recent data, add a date predicate to the MERGE `ON` clause so Spark rewrites only recent partitions.
- Compaction and snapshot expiry are handled by the managed table optimizers (no Athena 30-minute limit involved). Tune `snapshot_retention_days`.
- The Athena workgroup scan cap (`bytes_scanned_cutoff`, 100 GB in prod) applies to the quality-gate queries and Athena merges.
- The Glue merge path has not been run against real AWS yet: test with a small Parquet partition in dev first.
