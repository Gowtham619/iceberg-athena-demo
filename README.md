# Iceberg lakehouse on S3 + Athena

Raw files on S3 -> Athena tables -> Apache Iceberg tables, with an event-driven automated load, quality gates, managed table maintenance,
self-service sandbox tables, monitoring and CI/CD. Infrastructure is Terraform; the `sql/` + Python scripts are a hands-on demo.

```
upstream writes dt=YYYY-MM-DD/*.parquet|csv, then the marker file _SUCCESS (last)
        |  S3 -> EventBridge (event-driven; no polling)
        v
Step Functions: check files -> data-quality gate -> MERGE
        |         (Athena MERGE, or the Glue Spark merge job for large upserts)
        v
Iceberg tables (Parquet, KMS)  <-- managed optimizers: compaction, snapshot expiry, orphan cleanup
        ^                                  (enabled automatically on EVERY Iceberg table, incl. analysts')
analysts create their own tables in <db>_sandbox (sandbox/<user>/), query via the Athena workgroup

06:00 UTC catch-up run = SLA safety net: loads yesterday if an event was missed, ALERTS if data never arrived
Alerts -> SNS (email/PagerDuty/Chatbot); CloudWatch dashboard, freshness alarms, budget
```

## Layout
| Path | What |
|---|---|
| `bootstrap/` | one-time: Terraform state bucket + GitHub OIDC roles |
| `terraform/` | the stack (`envs/dev|prod.tfvars` + `*.backend.hcl`) |
| `terraform/pipelines/*.yaml` | one file per daily pipeline (source, checks, MERGE) |
| `terraform/lambda`, `terraform/glue` | ingest task Lambda, optimizer-enabler Lambda, Glue Spark merge job |
| `tests/` | unit tests for the ingest logic (`pytest`) |
| `.github/workflows/terraform.yml` | fmt/validate/tflint/checkov/tests -> plan on PR -> apply dev -> approve -> apply prod |
| `docs/RUNBOOK.md` | setup, operations, alert response, DR, accepted limits |
| `sql/`, `generate_*.py`, `run_sql.py` | demo scripts (**dev only**: they `DROP TABLE`) |

## Production controls included
- **State**: remote S3 state with native locking; separate state per environment.
- **Data protection**: separate data / query-results / access-log buckets; KMS CMK (rotating); TLS-only; public access blocked;
  versioning + non-current expiry; `prevent_destroy` on the data bucket and key; S3 access logging.
- **Reliability**: event-driven (no polling) Step Functions orchestration with retries, Spark merge for large data, idempotent MERGE,
  per-pipeline failure isolation; the execution FAILS (and alerts) if any pipeline fails; daily catch-up/SLA run.
- **Table maintenance**: Glue Data Catalog managed optimizers (auto compaction, snapshot expiry, orphan-file deletion) on every Iceberg table.
- **Data quality** (before MERGE): minimum rows, NOT NULL columns, duplicate keys.
- **Observability**: failure alerts, per-pipeline freshness alarms (no load in 36h), dashboard (runs, rows, scan volume), log retention.
- **Governance**: sandbox DB; each analyst limited to `sandbox/<username>/` (IAM, or Lake Formation when enabled); curated tables read-only.
- **Cost**: Athena scan limit per query, results expiry, monthly budget alert, cost-allocation tags.
- **Delivery**: CI/CD with OIDC (no static keys), prod approval gate, security scan.

## Deploy (short version - full steps in docs/RUNBOOK.md)
```bash
cd bootstrap && terraform init && terraform apply          # once per account
cd ../terraform
terraform init -backend-config=envs/dev.backend.hcl
terraform apply -var-file=envs/dev.tfvars
eval "$(terraform output -raw demo_env_exports)"           # BUCKET, DB, WORKGROUP, AWS_REGION
```

## Try the data flow (dev)
```bash
python generate_data.py --batch 1                     # raw CSV -> s3://$BUCKET/raw/orders/
python run_sql.py sql/01_setup_and_raw_table.sql      # plain Athena table over the CSV
python run_sql.py sql/03_create_iceberg_ddl_insert.sql# Iceberg table (DDL + INSERT SELECT); optimizers are enabled on it automatically
python run_sql.py sql/02_create_iceberg_ctas.sql      # (alternative) Iceberg via CTAS
python run_sql.py sql/07_raw_daily_partitioned.sql    # landing table for daily drops
python generate_daily.py --dt 2026-11-17              # data, then the _SUCCESS marker -> the load starts by itself
# watch it: Step Functions console -> <project>-<env>-daily-ingest  (or backfill by hand:)
aws stepfunctions start-execution --state-machine-arn "$(cd terraform && terraform output -raw ingest_state_machine_arn)" \
  --input '{"dt":"2026-11-17"}'
python run_sql.py sql/05_time_travel_and_metadata.sql # snapshots, time travel, schema evolution
```

## Analyst template (own table in their own space)
```sql
CREATE TABLE lakehouse_prod_sandbox.my_orders_2026
WITH (table_type='ICEBERG', format='PARQUET', is_external=false,
      location='s3://<data-bucket>/sandbox/<my-username>/my_orders_2026/')
AS SELECT * FROM lakehouse_prod.orders_iceberg WHERE order_date >= DATE '2026-06-01';
```

## Status / honesty
Written and unit-tested for the Python logic (`pytest`: 14 tests), HCL syntax-checked. **Not applied to a real AWS account** (no
credentials/Terraform in the authoring environment): run `terraform validate/plan` in dev first and expect to fix small issues.
Lake Formation mode is the least-proven part - keep `enable_lake_formation = false` until validated.
