import sys
from pyspark.context import SparkContext
from pyspark.sql import SparkSession

sc = SparkContext.getOrCreate()
spark = SparkSession.builder.getOrCreate()

# Script generated for node CatalogDataSource
CatalogDataSource_1779224919482 = spark.sql("select * from `smus-seed-db-curated`.`smus_seed_customers`")
# Script generated for node S3DataSink
CatalogDataSource_1779224919482.write.format("parquet") \
    .option("path", "s3://amazon-datazone-tooling-571600872292-us-east-1/dzd-6stcr0j6y0elwn/cynxyg1bf9zk4n/dev/test_customer_tab") \
    .option("compression", "snappy") \
    .mode("append") \
    .saveAsTable("`smus-seed-db-curated`.`test_customer_tab`")
