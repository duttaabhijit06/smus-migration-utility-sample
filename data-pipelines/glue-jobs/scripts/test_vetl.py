import sys
from pyspark.context import SparkContext
from pyspark.sql import SparkSession

sc = SparkContext.getOrCreate()
spark = SparkSession.builder.getOrCreate()

# Script generated for node CatalogDataSource
CatalogDataSource_1779150272086 = spark.sql("select * from `glue_db_55fpy5kjnn2iav`.`smus_seed_customers`")
# Script generated for node S3DataSink
additional_iceberg_options = {"write.parquet.compression-codec": "snappy"}
tables_collection = spark.catalog.listTables("smus-seed-db-curated")
table_names_in_db = [table.name for table in tables_collection]
table_exists = "test_table" in table_names_in_db
if table_exists:
    CatalogDataSource_1779150272086.writeTo("glue_catalog.`smus-seed-db-curated`.`test_table`") \
        .tableProperty("format-version", "2") \
        .tableProperty("location", "s3://amazon-datazone-tooling-571600872292-us-east-1/dzd-65qqhbh8pvk25j/4cg52523ckx0h3/dev/test_table") \
        .partitionedBy("signup_date") \
        .options(**additional_iceberg_options) \
        .append()
else:
    CatalogDataSource_1779150272086.writeTo("glue_catalog.`smus-seed-db-curated`.`test_table`") \
        .tableProperty("format-version", "2") \
        .tableProperty("location", "s3://amazon-datazone-tooling-571600872292-us-east-1/dzd-65qqhbh8pvk25j/4cg52523ckx0h3/dev/test_table") \
        .partitionedBy("signup_date") \
        .options(**additional_iceberg_options) \
        .create()
