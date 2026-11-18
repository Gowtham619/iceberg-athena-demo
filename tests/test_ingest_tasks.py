import json
import os
import sys
import unittest
from unittest import mock

os.environ.update({
    "AWS_DEFAULT_REGION": "us-east-1", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x",
    "DATA_BUCKET": "bkt", "WORKGROUP": "wg", "ARRIVAL_MAX_ATTEMPTS": "16",
})
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "terraform", "lambda"))
import ingest_tasks as t  # noqa: E402

ITEM = {
    "name": "orders", "dt": "2026-11-17", "attempt": 0, "max_attempts": 3,
    "source_table": "db.raw", "partition_column": "dt", "s3_prefix": "raw/x/dt=2026-11-17/",
    "ready_marker": "", "merge_sql": "MERGE ...",
    "checks": {"min_rows": 5, "key_columns": ["id"], "not_null": ["id", "d"]},
}
CONFIG = [
    {"name": "orders", "merge_sql": "MERGE WHERE dt='{{dt}}'",
     "source": {"table": "db.raw", "partition_column": "dt", "s3_prefix": "raw/o/dt={{dt}}/", "ready_marker": "_SUCCESS"},
     "checks": {"min_rows": 1}},
    {"name": "big", "engine": "glue", "merge_sql": "MERGE big {{dt}}",
     "source": {"table": "db.o", "s3_prefix": "raw/p/{{dt}}/", "format": "parquet", "ready_marker": "_SUCCESS"}},
    {"name": "nomarker", "merge_sql": "x", "source": {"table": "db.n", "s3_prefix": "raw/n/dt={{dt}}/"}},
]


def config_body():
    body = mock.Mock()
    body.read.return_value = json.dumps(CONFIG).encode()
    return {"Body": body}


class Helpers(unittest.TestCase):
    def test_resolve_dt(self):
        self.assertRegex(t.resolve_dt(None), r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(t.resolve_dt("2026-01-02"), "2026-01-02")
        for bad in ("2026-1-2", "x'; DROP", "2026-01-02 "):
            with self.assertRaises(ValueError):
                t.resolve_dt(bad)

    def test_ident_rejects_injection(self):
        with self.assertRaises(ValueError):
            t.ident("db.t; DROP TABLE x")

    def test_quality(self):
        stats, dups = t.quality_queries(ITEM)
        self.assertIn("count_if(id IS NULL) AS null_id", stats)
        self.assertIn("GROUP BY id HAVING count(*) > 1", dups)
        self.assertIsNone(t.quality_queries({**ITEM, "checks": {"min_rows": 1}})[1])
        self.assertEqual(t.evaluate_quality(ITEM, ["10", "0", "0"], 0), (10, []))
        self.assertEqual(len(t.evaluate_quality(ITEM, ["3", "1", "0"], 2)[1]), 3)

    def test_arrival_ready(self):
        self.assertFalse(t.arrival_ready([], ""))
        self.assertFalse(t.arrival_ready([{"Key": "raw/x/a.csv", "Size": 0}], ""))
        self.assertTrue(t.arrival_ready([{"Key": "raw/x/a.csv", "Size": 5}], ""))
        self.assertFalse(t.arrival_ready([{"Key": "raw/x/a.csv", "Size": 5}], "_SUCCESS"))
        self.assertTrue(t.arrival_ready([{"Key": "raw/x/_SUCCESS", "Size": 0}], "_SUCCESS"))

    def test_match_marker(self):
        p, dt = t.match_marker("raw/o/dt=2026-11-17/_SUCCESS", CONFIG)
        self.assertEqual((p["name"], dt), ("orders", "2026-11-17"))
        p, dt = t.match_marker("raw/p/2026-11-18/_SUCCESS", CONFIG)
        self.assertEqual((p["name"], dt), ("big", "2026-11-18"))
        for key in ("raw/o/dt=2026-11-17/data.csv", "raw/o/dt=bad/_SUCCESS", "other/o/dt=2026-11-17/_SUCCESS",
                    "raw/n/dt=2026-11-17/_SUCCESS"):  # last one: pipeline without a marker never matches
            self.assertEqual(t.match_marker(key, CONFIG), (None, None))


class Plan(unittest.TestCase):
    def test_s3_trigger_builds_single_item_no_waiting(self):
        with mock.patch.object(t._s3, "get_object", return_value=config_body()):
            out = t.plan({"event": {"trigger": "s3", "key": "raw/o/dt=2026-11-17/_SUCCESS"}})
        self.assertEqual(out["dt"], "2026-11-17")
        (item,) = out["items"]
        self.assertEqual((item["name"], item["max_attempts"], item["engine"]), ("orders", 1, "athena"))
        self.assertEqual(item["merge_sql"], "MERGE WHERE dt='2026-11-17'")
        self.assertEqual(item["source_uri"], "s3://bkt/raw/o/dt=2026-11-17/")

    def test_s3_trigger_unmatched_key_is_ignored(self):
        with mock.patch.object(t._s3, "get_object", return_value=config_body()):
            out = t.plan({"event": {"trigger": "s3", "key": "raw/zzz/dt=2026-11-17/_SUCCESS"}})
        self.assertEqual(out, {"dt": None, "items": []})

    def test_glue_engine_item_gets_sql_uri_in_s3(self):
        with mock.patch.object(t._s3, "get_object", return_value=config_body()), \
             mock.patch.object(t._s3, "put_object") as put:
            out = t.plan({"event": {"trigger": "s3", "key": "raw/p/2026-11-18/_SUCCESS"}})
        item = out["items"][0]
        self.assertEqual(item["engine"], "glue")
        self.assertEqual(item["merge_sql_uri"], "s3://bkt/_system/runs/2026-11-18/big.sql")
        self.assertEqual(put.call_args.kwargs["Body"], b"MERGE big 2026-11-18")

    def test_catchup_skips_done_and_does_not_wait(self):
        with mock.patch.object(t._s3, "get_object", return_value=config_body()), \
             mock.patch.object(t._s3, "put_object"), \
             mock.patch.object(t, "is_done", side_effect=lambda name, dt: name == "orders"):
            out = t.plan({"event": {"trigger": "catchup", "dt": "2026-11-17"}})
        self.assertEqual([i["name"] for i in out["items"]], ["big", "nomarker"])
        self.assertTrue(all(i["max_attempts"] == 1 for i in out["items"]))

    def test_manual_run_waits_and_can_filter(self):
        with mock.patch.object(t._s3, "get_object", return_value=config_body()):
            out = t.plan({"event": {"dt": "2026-11-10", "pipeline": "nomarker"}})
        (item,) = out["items"]
        self.assertEqual((item["name"], item["max_attempts"], out["dt"]), ("nomarker", 16, "2026-11-10"))

    def test_is_done(self):
        with mock.patch.object(t._s3, "list_objects_v2", return_value={"Contents": [{"Key": "k"}]}) as ls:
            self.assertTrue(t.is_done("orders", "2026-11-17"))
        self.assertEqual(ls.call_args.kwargs["Prefix"], "_system/state/orders/2026-11-17.done")
        with mock.patch.object(t._s3, "list_objects_v2", return_value={}):
            self.assertFalse(t.is_done("orders", "2026-11-17"))


class Actions(unittest.TestCase):
    def test_check_arrival_uses_marker_prefix_and_counts_attempts(self):
        item = {**ITEM, "ready_marker": "_SUCCESS"}
        with mock.patch.object(t._s3, "list_objects_v2",
                               return_value={"Contents": [{"Key": "raw/x/dt=2026-11-17/_SUCCESS", "Size": 0}]}) as ls:
            out = t.check_arrival({"item": item})
        self.assertEqual(ls.call_args.kwargs["Prefix"], "raw/x/dt=2026-11-17/_SUCCESS")
        self.assertTrue(out["ready"])
        self.assertEqual(out["attempt"], 1)
        with mock.patch.object(t._s3, "list_objects_v2", return_value={}):
            self.assertFalse(t.check_arrival({"item": item})["ready"])

    def test_validate_passes_and_fails(self):
        with mock.patch.object(t, "run_athena", side_effect=[["10", "0", "0"], ["0"]]), \
             mock.patch.object(t, "put_metric") as pm:
            self.assertEqual(t.validate({"item": ITEM})["rows"], 10)
            pm.assert_called_once_with("SourceRows", 10, "orders")
        with mock.patch.object(t, "run_athena", side_effect=[["10", "2", "0"], ["4"]]), mock.patch.object(t, "put_metric"):
            with self.assertRaises(t.DataQualityError) as cm:
                t.validate({"item": ITEM})
        self.assertIn("NULLs in id", str(cm.exception))

    def test_finalize_writes_done_markers_and_raises_on_failure(self):
        with mock.patch.object(t, "put_metric") as pm, mock.patch.object(t._s3, "put_object") as put:
            out = t.finalize({"results": [{"name": "a", "status": "SUCCEEDED"}], "dt": "2026-11-17"})
        self.assertEqual(out["succeeded"], ["a"])
        pm.assert_called_once_with("SuccessfulLoads", 1, "a")
        self.assertEqual(put.call_args.kwargs["Key"], "_system/state/a/2026-11-17.done")
        with mock.patch.object(t, "put_metric"), mock.patch.object(t._s3, "put_object") as put:
            with self.assertRaises(RuntimeError):
                t.finalize({"results": [{"name": "a", "status": "SUCCEEDED"}, {"name": "b", "status": "FAILED"}], "dt": "2026-11-17"})
            self.assertEqual(put.call_count, 1)  # only the healthy pipeline is marked done; b stays eligible for catch-up

    def test_finalize_with_no_items(self):
        self.assertEqual(t.finalize({"results": [], "dt": None}), {"succeeded": []})

    def test_handler_dispatch(self):
        with mock.patch.dict(t.ACTIONS, {"finalize": lambda e: {"ok": 1}}):
            self.assertEqual(t.handler({"action": "finalize"}, None), {"ok": 1})


if __name__ == "__main__":
    unittest.main()
