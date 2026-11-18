"""Glue Spark job: upsert one day's source files into an Iceberg table (no Athena 30-min DML limit).

Args (from the ingest orchestrator job):
  --SOURCE_PATH    s3://bucket/raw/.../dt=YYYY-MM-DD/
  --SOURCE_FORMAT  csv | parquet
  --MERGE_SQL_URI  s3:// object holding the Spark SQL MERGE; the day's files are exposed as the
                   view `src`, the target is addressed as glue_catalog.<db>.<table>
"""
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

args = getResolvedOptions(sys.argv, ["JOB_NAME", "SOURCE_PATH", "SOURCE_FORMAT", "MERGE_SQL_URI"])

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

fmt = args["SOURCE_FORMAT"].lower()
if fmt == "csv":
    df = spark.read.option("header", "true").csv(args["SOURCE_PATH"])  # all strings: CAST in the MERGE SQL
elif fmt == "parquet":
    df = spark.read.parquet(args["SOURCE_PATH"])
else:
    raise ValueError(f"unsupported SOURCE_FORMAT {fmt!r}")

merge_sql = spark.sparkContext.wholeTextFiles(args["MERGE_SQL_URI"]).collect()[0][1].strip().rstrip(";")
df.createOrReplaceTempView("src")
print(f"Source rows: {df.count()}", flush=True)
spark.sql(merge_sql)
print("MERGE complete", flush=True)
job.commit()
