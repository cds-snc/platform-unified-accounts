/*
 * S3 bucket to store exported events
 */
module "idp_event_exporter_s3" {
  source            = "github.com/cds-snc/terraform-modules//S3?ref=v11.4.5"
  bucket_name       = "idp-event-exporter-${var.env}"
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
      id      = "expire_objects"
      enabled = true
      expiration = {
        days = "730"
      }
    }
  ]
}

data "aws_iam_policy_document" "idp_event_exporter_s3" {
  statement {
    sid    = "DenyDeleteObject"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = [
      "s3:DeleteObject"
    ]
    resources = [
      "${module.idp_event_exporter_s3.s3_bucket_arn}/*"
    ]
  }
}

/*
 * Lambda function to export events to S3
 */
locals {
  event_window_minutes = 5
}

module "idp_event_exporter_lambda" {
  source = "github.com/cds-snc/terraform-modules//lambda_schedule?ref=v11.4.5"

  lambda_name                = "idp-event-exporter"
  lambda_schedule_expression = "cron(0/${local.event_window_minutes} * * * ? *)"
  lambda_timeout             = "60"
  lambda_architectures       = ["arm64"]
  lambda_ecr_arn             = aws_ecr_repository.repo["idp-event-exporter"].arn
  lambda_image_uri           = aws_ecr_repository.repo["idp-event-exporter"].repository_url

  lambda_policies = [
    data.aws_iam_policy_document.idp_event_exporter_get_ssm_parameters.json,
    data.aws_iam_policy_document.idp_event_exporter_sqs.json
  ]

  lambda_environment_variables = {
    S3_BUCKET                    = module.idp_event_exporter_s3.s3_bucket_id
    ZITADEL_PRIVATE_KEY_SSM_PATH = aws_ssm_parameter.idp_event_exporter_key_json.name
    ZITADEL_URL                  = "idp.${var.domain}"
    WINDOW_MINUTES               = local.event_window_minutes
  }

  lambda_vpc_config = {
    subnet_ids         = module.idp_vpc.private_subnet_ids
    security_group_ids = [aws_security_group.idp_event_exporter.id]
  }

  create_ecr_repository = false
  s3_arn_write_path     = "${module.idp_event_exporter_s3.s3_bucket_arn}/*"
  billing_tag_value     = var.billing_tag_value
}

data "aws_iam_policy_document" "idp_event_exporter_get_ssm_parameters" {
  statement {
    sid    = "GetSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.idp_event_exporter_key_json.arn,
    ]
  }
}

resource "aws_ssm_parameter" "idp_event_exporter_key_json" {
  name  = "idp_event_exporter_key_json"
  type  = "SecureString"
  value = var.idp_event_exporter_key_json
  tags  = local.core_tags
}

#
# Athena queries to create a table that can be used to query events
#
resource "aws_athena_named_query" "idp_event_exporter_create_table" {
  name      = "Zitadel events: create table"
  workgroup = module.athena_access_logs.athena_workgroup_name
  database  = module.athena_access_logs.athena_database_name
  query = templatefile("${path.module}/athena_queries/zitadel_events_create_table.sql",
    {
      bucket_name   = module.idp_event_exporter_s3.s3_bucket_id
      database_name = module.athena_access_logs.athena_database_name
    }
  )
}

resource "aws_athena_named_query" "idp_event_exporter_select_by_type" {
  name      = "Zitadel events: select events by type"
  workgroup = module.athena_access_logs.athena_workgroup_name
  database  = module.athena_access_logs.athena_database_name
  query = templatefile("${path.module}/athena_queries/zitadel_events_select_by_type.sql",
    {
      database_name = module.athena_access_logs.athena_database_name
    }
  )
}


resource "aws_lambda_function_event_invoke_config" "idp_event_exporter" {
  function_name                = module.idp_event_exporter_lambda.lambda_function_name
  maximum_retry_attempts       = 2   # Maximum retry attempts for the Lambda function invocation
  maximum_event_age_in_seconds = 300 # Maximum age of the event before it is discarded (in seconds)
  destination_config {
    on_failure {
      destination = aws_sqs_queue.idp_event_exporter_dlq_queue.arn
    }
  }
}

data "aws_iam_policy_document" "idp_event_exporter_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_exporter_dlq_queue.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.sqs_dlq.arn]
  }
}

resource "aws_sqs_queue" "idp_event_exporter" {
  name                      = "idp-event-exporter"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

resource "aws_sqs_queue_redrive_policy" "idp_event_exporter" {
  queue_url = aws_sqs_queue.idp_event_exporter.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.idp_event_exporter_dlq_queue.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "idp_event_exporter" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_exporter.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.idp_event_exporter_sqs.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "idp_event_exporter" {
  queue_url = aws_sqs_queue.idp_event_exporter.id
  policy    = data.aws_iam_policy_document.idp_event_exporter.json
}

resource "aws_cloudwatch_event_rule" "idp_event_exporter_sqs" {
  name                = "idp-event-exporter-sqs-schedule"
  description         = "Triggers the idp-event-exporter event queue on a schedule"
  schedule_expression = "cron(0/${local.event_window_minutes} * * * ? *)"
  state               = "DISABLED"
  tags                = local.core_tags
}

resource "aws_cloudwatch_event_target" "idp_event_exporter_sqs" {
  rule      = aws_cloudwatch_event_rule.idp_event_exporter_sqs.name
  target_id = "idp-event-exporter-sqs"
  arn       = aws_sqs_queue.idp_event_exporter.arn
}