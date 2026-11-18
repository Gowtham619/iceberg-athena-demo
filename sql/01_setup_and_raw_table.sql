-- Step 1: database + a plain Athena (Hive-style) external table over the CSV already on S3.
CREATE DATABASE IF NOT EXISTS ${DB};

DROP TABLE IF EXISTS ${DB}.raw_orders;

CREATE EXTERNAL TABLE ${DB}.raw_orders (
  order_id    bigint,
  customer_id bigint,
  order_date  string,
  status      string,
  amount      double
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://${BUCKET}/raw/orders/'
TBLPROPERTIES ('skip.header.line.count'='1');

SELECT count(*) AS raw_rows FROM ${DB}.raw_orders;
