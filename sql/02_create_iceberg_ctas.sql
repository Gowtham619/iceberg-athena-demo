-- Step 2 (Option A): CTAS - create an Iceberg table AND load it from the raw table in one statement.
-- Data + Iceberg metadata land under s3://${BUCKET}/iceberg/orders_ctas/
DROP TABLE IF EXISTS ${DB}.orders_ctas;

CREATE TABLE ${DB}.orders_ctas
WITH (
  table_type   = 'ICEBERG',
  format       = 'PARQUET',
  is_external  = false,
  location     = 's3://${BUCKET}/iceberg/orders_ctas/',
  partitioning = ARRAY['month(order_date)']
) AS
SELECT order_id, customer_id, CAST(order_date AS date) AS order_date, status, amount
FROM ${DB}.raw_orders;

SELECT count(*) AS iceberg_rows FROM ${DB}.orders_ctas;
