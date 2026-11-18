#!/usr/bin/env python3
"""Run a .sql file against Athena, one statement at a time.

Placeholders ${BUCKET}, ${DB} are replaced from environment variables.
Usage: python run_sql.py sql/01_setup_and_raw_table.sql
"""
import os, re, sys, time

import boto3

BUCKET = os.environ.get("BUCKET")
DB = os.environ.get("DB", "iceberg_demo")
WORKGROUP = os.environ.get("WORKGROUP", "primary")  # must be Athena engine v3
REGION = os.environ.get("AWS_REGION", "us-east-1")

if not BUCKET:
    sys.exit("Set BUCKET (e.g. export BUCKET=my-demo-bucket)")

athena = boto3.client("athena", region_name=REGION)


def statements(path):
    text = open(path).read()
    text = re.sub(r"--.*", "", text)  # strip comments
    text = text.replace("${BUCKET}", BUCKET).replace("${DB}", DB)
    return [s.strip() for s in text.split(";") if s.strip()]


def run(sql):
    qid = athena.start_query_execution(
        QueryString=sql,
        WorkGroup=WORKGROUP,  # the workgroup enforces the (KMS-encrypted) results location
    )["QueryExecutionId"]
    while True:
        q = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = q["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
    if state != "SUCCEEDED":
        raise RuntimeError(q["Status"].get("StateChangeReason", state))
    return qid


def show(qid, limit=15):
    rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=limit + 1)["ResultSet"]["Rows"]
    for r in rows:
        print("   ", " | ".join(c.get("VarCharValue", "NULL") for c in r["Data"]))


def main():
    for sql in statements(sys.argv[1]):
        print("\n>>", " ".join(sql.split())[:110])
        qid = run(sql)
        if sql.lstrip().upper().startswith(("SELECT", "SHOW", "DESCRIBE")):
            show(qid)
        else:
            print("    OK")


if __name__ == "__main__":
    main()
