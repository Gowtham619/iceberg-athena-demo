#!/usr/bin/env python3
"""Generate sample order CSVs and upload them to S3.

  python generate_data.py --batch 1   # initial load  -> s3://$BUCKET/raw/orders/
  python generate_data.py --batch 2   # updates + new -> s3://$BUCKET/raw/orders_updates/
"""
import argparse, csv, io, os, random
from datetime import date, timedelta

import boto3

STATUSES = ["PLACED", "SHIPPED", "DELIVERED", "CANCELLED"]


def make_rows(start_id, n, seed):
    rnd = random.Random(seed)
    base = date(2026, 1, 1)
    for i in range(start_id, start_id + n):
        yield [
            i,
            rnd.randint(1, 500),
            (base + timedelta(days=rnd.randint(0, 270))).isoformat(),
            rnd.choice(STATUSES),
            round(rnd.uniform(5, 500), 2),
        ]


def to_csv(rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["order_id", "customer_id", "order_date", "status", "amount"])  # header (skipped in DDL)
    w.writerows(rows)
    return buf.getvalue()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--batch", type=int, choices=[1, 2], required=True)
    p.add_argument("--bucket", default=os.environ.get("BUCKET"))
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    a = p.parse_args()
    if not a.bucket:
        raise SystemExit("Set BUCKET or pass --bucket")

    s3 = boto3.client("s3", region_name=a.region)
    if a.batch == 1:
        rows = list(make_rows(1, 5000, seed=1))
        key = "raw/orders/orders_batch1.csv"
    else:
        # 200 changed existing orders (ids 1..200, new status/amount) + 300 brand-new orders
        changed = [r[:3] + ["DELIVERED", round(r[4] * 1.1, 2)] for r in make_rows(1, 200, seed=1)]
        new = list(make_rows(5001, 300, seed=2))
        rows = changed + new
        key = "raw/orders_updates/orders_batch2.csv"

    s3.put_object(Bucket=a.bucket, Key=key, Body=to_csv(rows).encode())
    print(f"Uploaded {len(rows)} rows to s3://{a.bucket}/{key}")


if __name__ == "__main__":
    main()
