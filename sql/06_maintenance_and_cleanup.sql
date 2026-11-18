-- Step 5: maintenance (manual, for the demo). In the deployed stack the Glue managed optimizers do compaction,
-- snapshot expiry and orphan-file cleanup automatically - you do not need to run these.

-- Compact small files created by repeated inserts/merges:
OPTIMIZE ${DB}.orders_iceberg REWRITE DATA USING BIN_PACK;

-- Expire old snapshots and delete orphaned files (honors vacuum_* table properties):
VACUUM ${DB}.orders_iceberg;

-- Cleanup (uncomment to tear down; also delete s3://${BUCKET}/ prefixes iceberg/ raw/ athena-results/ if desired):
-- DROP TABLE ${DB}.orders_iceberg;
-- DROP TABLE ${DB}.orders_ctas;
-- DROP TABLE ${DB}.raw_orders;
-- DROP TABLE ${DB}.raw_orders_updates;
-- DROP DATABASE ${DB};
