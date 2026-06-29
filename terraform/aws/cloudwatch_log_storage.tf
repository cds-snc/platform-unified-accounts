#
# Stream CloudWatch logs to S3 for long-term storage
#
locals {
  cloudwatch_log_groups = [
    module.idp_ecs.cloudwatch_log_group_name,
    module.login_ecs.cloudwatch_log_group_name,
    module.event_exporter_lambda.lambda_function_cloudwatch_log_group_name
  ]
}

#
# S3 bucket for storing CloudWatch logs
#
module "cloudwatch_log_storage" {
  source            = "github.com/cds-snc/terraform-modules//S3?ref=v11.3.5"
  bucket_name       = "idp-cloudwatch-log-storage-${var.env}"
  billing_tag_value = var.billing_tag_value

  versioning = {
    enabled = true
  }

  lifecycle_rule = [
    {
      id                                     = "remove_noncurrent_versions"
      enabled                                = true
      abort_incomplete_multipart_upload_days = "7"
      noncurrent_version_expiration = {
        days = "30"
      }
    },
    {
      id      = "transition_storage"
      enabled = true
      transition = [
        {
          days          = "90"
          storage_class = "STANDARD_IA"
        },
        {
          days          = "180"
          storage_class = "GLACIER"
        }
      ]
    },
    {
      id      = "expire_logs"
      enabled = true
      expiration = {
        days = "730"
      }
    }
  ]
}

#
# Kinesis Firehose delivery stream to send CloudWatch logs to S3
#
resource "aws_kinesis_firehose_delivery_stream" "cloudwatch_log_storage" {
  name        = "cloudwatch-log-storage"
  destination = "extended_s3"

  server_side_encryption {
    enabled = true
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_cloudwatch_log_storage.arn
    bucket_arn         = module.cloudwatch_log_storage.s3_bucket_arn
    compression_format = "GZIP"

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }
      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{logGroup:.logGroup}"
        }
      }
    }

    buffering_size      = 64
    buffering_interval  = 300
    prefix              = "logs/log_group=!{partitionKeyFromQuery:logGroup}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/!{firehose:error-output-type}/"
  }
}

#
# Create a subscription filter for each CloudWatch log group to send all logs to the Kinesis Firehose delivery stream
#
resource "aws_cloudwatch_log_subscription_filter" "firehose_subscription" {
  for_each = toset(local.cloudwatch_log_groups)

  name            = "firehose${replace(replace(each.value, "/", "-"), "_", "-")}"
  log_group_name  = each.value
  role_arn        = aws_iam_role.cloudwatch_log_storage.arn
  destination_arn = aws_kinesis_firehose_delivery_stream.cloudwatch_log_storage.arn
  filter_pattern  = "" # Forward all logs
}

#
# IAM roles and policies for CloudWatch log subscription and Kinesis Firehose
#
resource "aws_iam_role" "cloudwatch_log_storage" {
  name               = "cloudwatch-log-storage"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_log_storage_assume.json
}

resource "aws_iam_role_policy" "cloudwatch_log_storage" {
  name   = "cloudwatch-log-storage"
  role   = aws_iam_role.cloudwatch_log_storage.id
  policy = data.aws_iam_policy_document.cloudwatch_log_storage.json
}

data "aws_iam_policy_document" "cloudwatch_log_storage_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cloudwatch_log_storage" {
  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch"
    ]
    resources = [
      aws_kinesis_firehose_delivery_stream.cloudwatch_log_storage.arn
    ]
  }
}

resource "aws_iam_role" "firehose_cloudwatch_log_storage" {
  name               = "firehose_cloudwatch_log_storage"
  assume_role_policy = data.aws_iam_policy_document.firehose_cloudwatch_log_storage_assume.json
}

resource "aws_iam_role_policy" "firehose_cloudwatch_log_storage" {
  name   = "firehose_cloudwatch_log_storage"
  role   = aws_iam_role.firehose_cloudwatch_log_storage.id
  policy = data.aws_iam_policy_document.firehose_cloudwatch_log_storage.json
}

data "aws_iam_policy_document" "firehose_cloudwatch_log_storage_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "firehose_cloudwatch_log_storage" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    resources = [
      module.cloudwatch_log_storage.s3_bucket_arn,
      "${module.cloudwatch_log_storage.s3_bucket_arn}/*"
    ]
  }
}
