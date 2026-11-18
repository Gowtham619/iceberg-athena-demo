#!/usr/bin/env python3
"""Simulate one day's incoming file: python generate_daily.py --dt 2026-11-17
Writes s3://$BUCKET/raw/orders_daily/dt=<dt>/orders.csv  (new orders + a few corrections to existing ones),
then the _SUCCESS marker, which triggers the load."""
import argparse, os
import boto3
from generate_data import make_rows, to_csv

p = argparse.ArgumentParser()
p.add_argument("--dt", required=True)
p.add_argument("--bucket", default=os.environ.get("BUCKET"))
p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
p.add_argument("--no-marker", action="store_true", help="upload data only (does not trigger the load)")
a = p.parse_args()
if not a.bucket:
    raise SystemExit("Set BUCKET or pass --bucket")

seed = int(a.dt.replace("-", ""))
start = 10000 + (seed % 100000)                     # unique-ish ids per day
new = list(make_rows(start, 200, seed))
fixes = [r[:3] + ["DELIVERED", r[4]] for r in make_rows(1, 20, seed=1)]  # re-send 20 old orders as DELIVERED
key = f"raw/orders_daily/dt={a.dt}/orders.csv"
s3 = boto3.client("s3", region_name=a.region)
s3.put_object(Bucket=a.bucket, Key=key, Body=to_csv(new + fixes).encode())
print(f"Uploaded {len(new) + len(fixes)} rows to s3://{a.bucket}/{key}")
if not a.no_marker:  # the marker goes LAST: its arrival is what starts the load (S3 -> EventBridge -> Step Functions)
    marker = f"raw/orders_daily/dt={a.dt}/_SUCCESS"
    s3.put_object(Bucket=a.bucket, Key=marker, Body=b"")
    print(f"Wrote marker s3://{a.bucket}/{marker}  -> the pipeline starts automatically")
