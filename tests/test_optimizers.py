import os
import sys
import unittest
from unittest import mock

from botocore.exceptions import ClientError

os.environ.update({
    "AWS_DEFAULT_REGION": "us-east-1", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x",
    "DATABASES": "lake_dev,lake_dev_sandbox", "OPTIMIZER_ROLE_ARN": "arn:aws:iam::1:role/opt",
    "SNAPSHOT_RETENTION_DAYS": "7", "ORPHAN_RETENTION_DAYS": "3",
})
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "terraform", "lambda"))
import optimizers as o  # noqa: E402


def not_found():
    return ClientError({"Error": {"Code": "EntityNotFoundException", "Message": "x"}}, "GetTableOptimizer")


ICE = {"Name": "orders", "Parameters": {"table_type": "ICEBERG"}, "StorageDescriptor": {"Location": "s3://b/iceberg/orders/"}}
HIVE = {"Name": "raw", "Parameters": {"classification": "csv"}}


class Optimizers(unittest.TestCase):
    def test_is_iceberg(self):
        self.assertTrue(o.is_iceberg(ICE))
        self.assertFalse(o.is_iceberg(HIVE))

    def test_configs(self):
        cfg = o.optimizer_configs("s3://b/t/")
        self.assertEqual(set(cfg), {"compaction", "retention", "orphan_file_deletion"})
        self.assertEqual(cfg["retention"]["retentionConfiguration"]["icebergConfiguration"]["snapshotRetentionPeriodInDays"], 7)
        self.assertEqual(cfg["orphan_file_deletion"]["orphanFileDeletionConfiguration"]["icebergConfiguration"]["location"], "s3://b/t/")

    def test_ensure_creates_only_missing(self):
        def get(**kw):
            if kw["Type"] == "compaction":
                return {}
            raise not_found()
        with mock.patch.object(o._glue, "get_table_optimizer", side_effect=get), \
             mock.patch.object(o._glue, "create_table_optimizer") as create:
            created = o.ensure("lake_dev", ICE)
        self.assertEqual(created, ["retention", "orphan_file_deletion"])
        self.assertEqual(create.call_count, 2)
        self.assertEqual(create.call_args_list[0].kwargs["TableName"], "orders")

    def test_ensure_propagates_unexpected_errors(self):
        err = ClientError({"Error": {"Code": "AccessDeniedException", "Message": "no"}}, "GetTableOptimizer")
        with mock.patch.object(o._glue, "get_table_optimizer", side_effect=err):
            with self.assertRaises(ClientError):
                o.ensure("lake_dev", ICE)

    def test_event_for_new_table(self):
        event = {"detail": {"databaseName": "lake_dev_sandbox", "tableName": "orders", "typeOfChange": "CreateTable"}}
        with mock.patch.object(o._glue, "get_table", return_value={"Table": ICE}), \
             mock.patch.object(o, "ensure", return_value=["compaction"]) as ens:
            out = o.handler(event, None)
        ens.assert_called_once()
        self.assertEqual(out["checked"], 1)

    def test_event_for_non_iceberg_table_is_skipped(self):
        event = {"detail": {"databaseName": "lake_dev", "tableName": "raw"}}
        with mock.patch.object(o._glue, "get_table", return_value={"Table": HIVE}), mock.patch.object(o, "ensure") as ens:
            self.assertEqual(o.handler(event, None)["checked"], 0)
        ens.assert_not_called()

    def test_reconcile_covers_all_iceberg_tables_and_reports_failures(self):
        tables = [("lake_dev", ICE), ("lake_dev_sandbox", {**ICE, "Name": "mine"})]
        with mock.patch.object(o, "iceberg_tables", return_value=iter(tables)), \
             mock.patch.object(o, "ensure", side_effect=[[], RuntimeError("boom")]):
            with self.assertRaises(RuntimeError) as cm:
                o.handler({}, None)
        self.assertIn("lake_dev_sandbox.mine", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
