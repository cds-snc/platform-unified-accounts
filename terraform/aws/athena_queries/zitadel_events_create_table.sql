CREATE EXTERNAL TABLE `${database_name}.zitadel_events` (
    editor STRUCT<
        userId:      STRING,
        displayName: STRING,
        service:     STRING
    >,
    aggregate STRUCT<
        id:            STRING,
        type:          STRUCT<
            type:      STRING,
            localized: STRUCT<
                key:              STRING,
                localizedMessage: STRING
            >
        >,
        resourceOwner: STRING
    >,
    sequence     BIGINT,
    creationDate STRING,
    payload      STRING,
    type STRUCT<
        type:      STRING,
        localized: STRUCT<
            key:              STRING,
            localizedMessage: STRING
        >
    >
)
PARTITIONED BY (
    year  STRING,
    month STRING,
    day   STRING
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES (
    'ignore.malformed.json' = 'true'
)
STORED AS INPUTFORMAT  'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT           'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://${bucket_name}/events/'
TBLPROPERTIES (
    'projection.enabled'        = 'true',
    'projection.year.type'      = 'integer',
    'projection.year.range'     = '2024,2030',
    'projection.year.digits'    = '4',
    'projection.month.type'     = 'integer',
    'projection.month.range'    = '01,12',
    'projection.month.digits'   = '2',
    'projection.day.type'       = 'integer',
    'projection.day.range'      = '01,31',
    'projection.day.digits'     = '2',
    'storage.location.template' = 's3://${bucket_name}/events/$${year}/$${month}/$${day}'
);