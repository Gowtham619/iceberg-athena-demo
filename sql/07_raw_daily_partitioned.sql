-- Landing table for DAILY files: s3://${BUCKET}/raw/orders_daily/dt=YYYY-MM-DD/*.csv
-- Partition projection = new daily folders are queryable immediately (no MSCK / crawler / ALTER ADD PARTITION).
-- When the upstream writes the day's _SUCCESS marker, Step Functions (terraform/pipelines/orders.yaml) MERGEs that partition into orders_iceberg.
-- Requires orders_iceberg from 03_create_iceberg_ddl_insert.sql.
CREATE EXTERNAL TABLE IF NOT EXISTS ${DB}.raw_orders_daily (
  order_id    bigint,
  customer_id bigint,
  order_date  string,
  status      string,
  amount      double
)
PARTITIONED BY (dt string)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://${BUCKET}/raw/orders_daily/'
TBLPROPERTIES (
  'skip.header.line.count'            = '1',
  'projection.enabled'            = 'true',
  'projection.dt.type'            = 'date',
  'projection.dt.format'          = 'yyyy-MM-dd',
  'projection.dt.range'           = '2026-01-01,NOW',
  'storage.location.template'     = 's3://${BUCKET}/raw/orders_daily/dt=${dt}/'
)
