"""Enable Glue Data Catalog *managed* Iceberg optimizers on every Iceberg table:
  compaction              merges small files automatically
  retention               expires old snapshots (bounds time-travel history + storage)
  orphan_file_deletion    removes unreferenced files
Triggered (a) when a table is created in our databases (EventBridge) so analyst tables are covered
immediately, and (b) daily as a reconcile for anything missed. Nothing to register per table.
"""
import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
DATABASES = [d for d in os.environ.get("DATABASES", "").split(",") if d]
ROLE_ARN = os.environ.get("OPTIMIZER_ROLE_ARN", "")
SNAPSHOT_DAYS = int(os.environ.get("SNAPSHOT_RETENTION_DAYS", "7"))
ORPHAN_DAYS = int(os.environ.get("ORPHAN_RETENTION_DAYS", "3"))

_glue = boto3.client("glue", region_name=REGION)


def is_iceberg(table):
    return table.get("Parameters", {}).get("table_type", "").upper() == "ICEBERG"


def optimizer_configs(location):
    return {
        "compaction": {"roleArn": ROLE_ARN, "enabled": True},
        "retention": {
            "roleArn": ROLE_ARN, "enabled": True,
            "retentionConfiguration": {"icebergConfiguration": {
                "snapshotRetentionPeriodInDays": SNAPSHOT_DAYS, "numberOfSnapshotsToRetain": 1, "cleanExpiredFiles": True}},
        },
        "orphan_file_deletion": {
            "roleArn": ROLE_ARN, "enabled": True,
            "orphanFileDeletionConfiguration": {"icebergConfiguration": {
                "orphanFileRetentionPeriodInDays": ORPHAN_DAYS, "location": location}},
        },
    }


def ensure(db, table):
    """Create any missing optimizer for one Iceberg table. Returns the list of optimizers created."""
    created = []
    location = table.get("StorageDescriptor", {}).get("Location", "")
    for opt_type, cfg in optimizer_configs(location).items():
        try:
            _glue.get_table_optimizer(DatabaseName=db, TableName=table["Name"], Type=opt_type)
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "EntityNotFoundException":
                raise
            _glue.create_table_optimizer(DatabaseName=db, TableName=table["Name"], Type=opt_type,
                                         TableOptimizerConfiguration=cfg)
            created.append(opt_type)
    return created


def iceberg_tables():
    for db in DATABASES:
        for page in _glue.get_paginator("get_tables").paginate(DatabaseName=db):
            for t in page["TableList"]:
                if is_iceberg(t):
                    yield db, t


def handler(event, context):
    detail = (event or {}).get("detail") or {}
    if detail.get("tableName") and detail.get("databaseName") in DATABASES:  # table-created event
        t = _glue.get_table(DatabaseName=detail["databaseName"], Name=detail["tableName"])["Table"]
        targets = [(detail["databaseName"], t)] if is_iceberg(t) else []
    else:  # scheduled reconcile
        targets = list(iceberg_tables())

    done, failed = {}, []
    for db, t in targets:
        try:
            done[f"{db}.{t['Name']}"] = ensure(db, t)
        except Exception as exc:
            failed.append(f"{db}.{t['Name']}: {exc}")
            print(f"FAILED {db}.{t['Name']}: {exc}")
    print(f"tables={len(targets)} newly_enabled={ {k: v for k, v in done.items() if v} } failed={len(failed)}")
    if failed:
        raise RuntimeError("; ".join(failed))
    return {"checked": len(targets), "enabled": {k: v for k, v in done.items() if v}}
