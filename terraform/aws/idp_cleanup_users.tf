/*
 * Lambda function to cleanup users
 */
module "idp_cleanup_users_lambda" {
  source = "github.com/cds-snc/terraform-modules//lambda_schedule?ref=v11.4.5"

  lambda_name                = "idp-cleanup-users"
  lambda_schedule_expression = "cron(0 0 * * ? *)" # Run every day at midnight UTC
  lambda_timeout             = "60"
  lambda_architectures       = ["arm64"]
  lambda_ecr_arn             = aws_ecr_repository.repo["idp-cleanup-users"].arn
  lambda_image_uri           = aws_ecr_repository.repo["idp-cleanup-users"].repository_url

  lambda_policies = [
    data.aws_iam_policy_document.idp_cleanup_users_get_ssm_parameters.json,
    data.aws_iam_policy_document.idp_cleanup_users_sqs.json
  ]

  lambda_environment_variables = {
    INACTIVE_DAYS                = 30
    ZITADEL_PRIVATE_KEY_SSM_PATH = aws_ssm_parameter.idp_cleanup_users_key_json.name
    ZITADEL_URL                  = "internal.${var.domain}"
    DRY_RUN                      = "false"
  }

  lambda_vpc_config = {
    subnet_ids         = module.idp_vpc.private_subnet_ids
    security_group_ids = [aws_security_group.idp_cleanup_users.id]
  }

  create_ecr_repository = false
  billing_tag_value     = var.billing_tag_value
}

data "aws_iam_policy_document" "idp_cleanup_users_get_ssm_parameters" {
  statement {
    sid    = "GetSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.idp_cleanup_users_key_json.arn,
    ]
  }
}

resource "aws_ssm_parameter" "idp_cleanup_users_key_json" {
  name  = "idp_cleanup_users_key_json"
  type  = "SecureString"
  value = var.idp_cleanup_users_key_json
  tags  = local.core_tags
}

resource "aws_lambda_function_event_invoke_config" "idp_cleanup_users_event_invoke_config" {
  function_name                = module.idp_cleanup_users_lambda.lambda_function_name
  maximum_retry_attempts       = 2   # Maximum retry attempts for the Lambda function invocation
  maximum_event_age_in_seconds = 300 # Maximum age of the event before it is discarded (in seconds)
  destination_config {
    on_failure {
      destination = aws_sqs_queue.idp_event_cleanup_users_dlq_queue.arn
    }
  }
}

data "aws_iam_policy_document" "idp_cleanup_users_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_cleanup_users_dlq_queue.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.sqs_dlq.arn]
  }
}
resource "aws_sqs_queue" "idp_event_cleanup_users" {
  name                      = "idp-cleanup-users"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

resource "aws_sqs_queue_redrive_policy" "idp_event_cleanup_users" {
  queue_url = aws_sqs_queue.idp_event_cleanup_users.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.idp_event_cleanup_users_dlq_queue.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "idp_event_cleanup_users" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_cleanup_users.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.idp_cleanup_users_sqs.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "idp_event_cleanup_users" {
  queue_url = aws_sqs_queue.idp_event_cleanup_users.id
  policy    = data.aws_iam_policy_document.idp_event_cleanup_users.json
}

resource "aws_cloudwatch_event_rule" "idp_cleanup_users_sqs" {
  name                = "idp-cleanup-users-sqs-schedule"
  description         = "Triggers the idp-cleanup-users event queue on a schedule"
  schedule_expression = "cron(0 0 * * ? *)"
  state               = "DISABLED"
  tags                = local.core_tags
}

resource "aws_cloudwatch_event_target" "idp_cleanup_users_sqs" {
  rule      = aws_cloudwatch_event_rule.idp_cleanup_users_sqs.name
  target_id = "idp-cleanup-users-sqs"
  arn       = aws_sqs_queue.idp_event_cleanup_users.arn
}