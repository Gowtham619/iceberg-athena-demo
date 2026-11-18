-- Step 2 (Option B): explicit DDL, then INSERT INTO ... SELECT. This is the table used for the rest of the demo.
DROP TABLE IF EXISTS ${DB}.orders_iceberg;

CREATE TABLE ${DB}.orders_iceberg (
  order_id    bigint,
  customer_id bigint,
  order_date  date,
  status      string,
  amount      double
)
PARTITIONED BY (month(order_date))
LOCATION 's3://${BUCKET}/iceberg/orders_iceberg/'
TBLPROPERTIES (
  'table_type' = 'ICEBERG',
  'format'     = 'parquet'
);

INSERT INTO ${DB}.orders_iceberg
SELECT order_id, customer_id, CAST(order_date AS date), status, amount
FROM ${DB}.raw_orders;

SELECT status, count(*) AS orders, round(sum(amount), 2) AS revenue
FROM ${DB}.orders_iceberg
GROUP BY status
ORDER BY status;
