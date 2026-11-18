-- Step 3: row-level changes - something plain Athena/Hive tables can't do.
-- Run AFTER: python generate_data.py --batch 2
DROP TABLE IF EXISTS ${DB}.raw_orders_updates;

CREATE EXTERNAL TABLE ${DB}.raw_orders_updates (
  order_id    bigint,
  customer_id bigint,
  order_date  string,
  status      string,
  amount      double
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://${BUCKET}/raw/orders_updates/'
TBLPROPERTIES ('skip.header.line.count'='1');

MERGE INTO ${DB}.orders_iceberg t
USING (
  SELECT order_id, customer_id, CAST(order_date AS date) AS order_date, status, amount
  FROM ${DB}.raw_orders_updates
) s
ON t.order_id = s.order_id
WHEN MATCHED THEN UPDATE SET status = s.status, amount = s.amount
WHEN NOT MATCHED THEN INSERT (order_id, customer_id, order_date, status, amount)
  VALUES (s.order_id, s.customer_id, s.order_date, s.status, s.amount);

DELETE FROM ${DB}.orders_iceberg WHERE status = 'CANCELLED';

SELECT count(*) AS rows_after_merge FROM ${DB}.orders_iceberg;
