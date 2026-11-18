"""Task Lambda used by the ingest Step Functions workflow.

Triggers (execution input):
  {"trigger":"s3","key":"raw/.../dt=2026-11-17/_SUCCESS"}  upstream finished writing a day -> load exactly that pipeline/day
  {"trigger":"catchup"}                                     SLA check: load yesterday for pipelines not yet loaded; alerts if data never arrived
  {"dt":"2026-11-10","pipeline":"orders"}                   manual backfill / re-run (waits for files up to ARRIVAL_MAX_ATTEMPTS)

Actions (event["action"]): plan | check_arrival | validate | finalize.
The MERGE itself is run by Step Functions (Athena integration) or the Glue Spark merge job.
"""
import datetime as dt_mod
import json
import os
import re
import time

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
DATA_BUCKET = os.environ.get("DATA_BUCKET", "")
WORKGROUP = os.environ.get("WORKGROUP", "primary")
CONFIG_KEY = os.environ.get("CONFIG_KEY", "_system/config/pipelines.json")
NAMESPACE = os.environ.get("METRIC_NAMESPACE", "LakehousePipelines")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
MAX_ATTEMPTS = int(os.environ.get("ARRIVAL_MAX_ATTEMPTS", "16"))

_s3 = boto3.client("s3", region_name=REGION)
_athena = boto3.client("athena", region_name=REGION)
_cw = boto3.client("cloudwatch", region_name=REGION)

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DT_RE = r"\d{4}-\d{2}-\d{2}"


class DataQualityError(Exception):
    pass


# ----------------------------------------------------------------- helpers
def resolve_dt(value):
    dt = value or (dt_mod.datetime.now(dt_mod.timezone.utc).date() - dt_mod.timedelta(days=1)).isoformat()
    if not DATE.match(dt):
        raise ValueError(f"dt must be YYYY-MM-DD, got {dt!r}")
    return dt


def render(template, dt):
    return template.replace("{{dt}}", dt)


def ident(value):
    if not IDENT.match(value):
        raise ValueError(f"unsafe identifier in pipeline config: {value!r}")
    return value


def marker_regex(pipeline):
    """Regex matching '<s3_prefix><ready_marker>' with {{dt}} captured as group 'dt'."""
    src = pipeline["source"]
    template = src["s3_prefix"] + src.get("ready_marker", "")
    parts = template.split("{{dt}}")
    out = re.escape(parts[0])
    for i, part in enumerate(parts[1:]):
        out += (f"(?P<dt>{DT_RE})" if i == 0 else "(?P=dt)") + re.escape(part)
    return re.compile(out)


def match_marker(key, pipelines):
    """Which pipeline/day does this S3 marker key complete? -> (pipeline, dt) or (None, None)."""
    for p in pipelines:
        if not p["source"].get("ready_marker"):
            continue  # pipelines without a marker are only loaded by the catch-up run / manually
        m = marker_regex(p).fullmatch(key)
        if m:
            return p, m.group("dt") if "dt" in m.groupdict() and m.group("dt") else None
    return None, None


def done_key(name, dt):
    return f"_system/state/{name}/{dt}.done"


def is_done(name, dt):
    resp = _s3.list_objects_v2(Bucket=DATA_BUCKET, Prefix=done_key(name, dt), MaxKeys=1)
    return bool(resp.get("Contents"))


def quality_queries(item):
    """Return (stats_sql, duplicates_sql or None)."""
    src = ident(item["source_table"])
    where = f"{ident(item['partition_column'])} = '{item['dt']}'"
    checks = item.get("checks") or {}
    not_null = [ident(c) for c in checks.get("not_null", [])]
    keys = [ident(c) for c in checks.get("key_columns", [])]
    cols = ["count(*) AS total"] + [f"count_if({c} IS NULL) AS null_{c}" for c in not_null]
    stats = f"SELECT {', '.join(cols)} FROM {src} WHERE {where}"
    dups = None
    if keys:
        dups = (f"SELECT count(*) FROM (SELECT 1 FROM {src} WHERE {where} "
                f"GROUP BY {', '.join(keys)} HAVING count(*) > 1)")
    return stats, dups


def evaluate_quality(item, stats_row, dup_count):
    checks = item.get("checks") or {}
    problems = []
    total = int(stats_row[0])
    if total < int(checks.get("min_rows", 1)):
        problems.append(f"only {total} rows (min {checks.get('min_rows', 1)})")
    for i, col in enumerate(checks.get("not_null", [])):
        nulls = int(stats_row[1 + i])
        if nulls:
            problems.append(f"{nulls} NULLs in {col}")
    if dup_count:
        problems.append(f"{dup_count} duplicate key groups on {checks.get('key_columns')}")
    return total, problems


def arrival_ready(objects, marker):
    """objects: list of {Key, Size}. Ready = marker file present, else any non-empty object."""
    real = [o for o in objects if not o["Key"].endswith("/")]
    if marker:
        return any(o["Key"].endswith(marker) for o in real)
    return any(o.get("Size", 0) > 0 for o in real)


def run_athena(sql):
    qid = _athena.start_query_execution(QueryString=sql, WorkGroup=WORKGROUP)["QueryExecutionId"]
    while True:
        status = _athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        if status["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1.5)
    if status["State"] != "SUCCEEDED":
        raise RuntimeError(f"Athena {status['State']}: {status.get('StateChangeReason', '')}")
    rows = _athena.get_query_results(QueryExecutionId=qid, MaxResults=2)["ResultSet"]["Rows"]
    return [c.get("VarCharValue") for c in rows[1]["Data"]]  # rows[0] is the header


def put_metric(name, value, pipeline):
    _cw.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[{
            "MetricName": name, "Value": value,
            "Dimensions": [{"Name": "Pipeline", "Value": pipeline}, {"Name": "Environment", "Value": ENVIRONMENT}],
        }],
    )


# ----------------------------------------------------------------- actions
def make_item(p, dt, max_attempts):
    src = p["source"]
    prefix = render(src["s3_prefix"], dt)
    item = {
        "name": p["name"], "dt": dt, "attempt": 0, "max_attempts": max_attempts,
        "engine": p.get("engine", "athena"),  # athena | glue (Spark merge job, for large upserts)
        "merge_sql": render(p["merge_sql"], dt),
        "source_table": src["table"], "partition_column": src.get("partition_column", "dt"),
        "s3_prefix": prefix, "source_uri": f"s3://{DATA_BUCKET}/{prefix}",
        "source_format": src.get("format", "csv"), "ready_marker": src.get("ready_marker", ""),
        "checks": p.get("checks", {}),
    }
    if item["engine"] == "glue":  # the Spark job reads the SQL from S3 (no job-argument size limit)
        key = f"_system/runs/{dt}/{p['name']}.sql"
        _s3.put_object(Bucket=DATA_BUCKET, Key=key, Body=item["merge_sql"].encode())
        item["merge_sql_uri"] = f"s3://{DATA_BUCKET}/{key}"
    return item


def plan(event):
    ex = event.get("event") or {}
    pipelines = json.loads(_s3.get_object(Bucket=DATA_BUCKET, Key=CONFIG_KEY)["Body"].read())
    trigger = ex.get("trigger")

    if trigger == "s3":
        p, dt = match_marker(ex.get("key", ""), pipelines)
        if not p:
            print(f"ignoring marker that matches no pipeline: {ex.get('key')}")
            return {"dt": None, "items": []}
        return {"dt": dt, "items": [make_item(p, dt, 1)]}  # the marker exists, so no waiting

    dt = resolve_dt(ex.get("dt"))
    if ex.get("pipeline"):
        pipelines = [p for p in pipelines if p["name"] == ex["pipeline"]]
    if trigger == "catchup":
        pipelines = [p for p in pipelines if not is_done(p["name"], dt)]
        attempts = 1  # SLA check: do not wait; if the data is still missing the run fails -> alert
    else:
        attempts = MAX_ATTEMPTS  # manual run: wait for late files
    return {"dt": dt, "items": [make_item(p, dt, attempts) for p in pipelines]}


def check_arrival(event):
    item = event["item"]
    marker = item.get("ready_marker", "")
    resp = _s3.list_objects_v2(Bucket=DATA_BUCKET, Prefix=item["s3_prefix"] + marker, MaxKeys=1000)
    ready = arrival_ready(resp.get("Contents", []), marker)
    print(f"[{item['name']}] dt={item['dt']} ready={ready} attempt={item['attempt'] + 1}/{item['max_attempts']}")
    return {**item, "ready": ready, "attempt": item["attempt"] + 1}


def validate(event):
    item = event["item"]
    stats_sql, dups_sql = quality_queries(item)
    stats_row = run_athena(stats_sql)
    dup_count = int(run_athena(dups_sql)[0]) if dups_sql else 0
    total, problems = evaluate_quality(item, stats_row, dup_count)
    put_metric("SourceRows", total, item["name"])
    if problems:
        raise DataQualityError(f"[{item['name']}] dt={item['dt']}: " + "; ".join(problems))
    print(f"[{item['name']}] quality OK ({total} rows)")
    return {"name": item["name"], "rows": total}


def finalize(event):
    results, dt = event["results"], event.get("dt")
    for r in results:
        if r.get("status") == "SUCCEEDED":
            put_metric("SuccessfulLoads", 1, r["name"])
            _s3.put_object(Bucket=DATA_BUCKET, Key=done_key(r["name"], dt),
                           Body=json.dumps({"loaded_at": dt_mod.datetime.now(dt_mod.timezone.utc).isoformat()}).encode())
    failed = [r for r in results if r.get("status") != "SUCCEEDED"]
    if failed:
        raise RuntimeError("Pipelines failed: " + json.dumps(failed)[:1500])
    return {"succeeded": [r["name"] for r in results]}


ACTIONS = {"plan": plan, "check_arrival": check_arrival, "validate": validate, "finalize": finalize}


def handler(event, context):
    return ACTIONS[event["action"]](event)
