-- Step 4: Iceberg snapshots, time travel, metadata tables, schema evolution.

-- Every INSERT / MERGE / DELETE created a snapshot:
SELECT snapshot_id, committed_at, operation FROM "${DB}"."orders_iceberg$snapshots" ORDER BY committed_at;

-- Commit history:
SELECT * FROM "${DB}"."orders_iceberg$history" ORDER BY made_current_at;

-- Time travel by timestamp. Use a time after the initial INSERT but before the MERGE (UTC), e.g.:
--   SELECT count(*) FROM ${DB}.orders_iceberg FOR TIMESTAMP AS OF TIMESTAMP '2026-11-18 10:00:00 UTC';
-- Time travel by snapshot id (copy one from the query above):
--   SELECT count(*) FROM ${DB}.orders_iceberg FOR VERSION AS OF 1234567890123456789;

-- Partitions and data files:
SELECT * FROM "${DB}"."orders_iceberg$partitions" LIMIT 12;
SELECT file_path, record_count, file_size_in_bytes FROM "${DB}"."orders_iceberg$files" LIMIT 5;

-- Schema evolution (metadata-only, no rewrite):
ALTER TABLE ${DB}.orders_iceberg ADD COLUMNS (channel string);

SELECT order_id, status, channel FROM ${DB}.orders_iceberg LIMIT 5;
