/*
 * Lambda function to cleanup users
 */
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
  state               = "ENABLED"
  tags                = local.core_tags
}

resource "aws_cloudwatch_event_target" "idp_cleanup_users_sqs" {
  rule      = aws_cloudwatch_event_rule.idp_cleanup_users_sqs.name
  target_id = "idp-cleanup-users-sqs"
  arn       = aws_sqs_queue.idp_event_cleanup_users.arn
}

module "idp_cleanup_users" {
  source = "github.com/cds-snc/terraform-modules//lambda?ref=v11.4.7"

  name      = "idp-cleanup-users"
  image_uri = "${aws_ecr_repository.repo["idp-cleanup-users"].repository_url}:latest"
  ecr_arn   = aws_ecr_repository.repo["idp-cleanup-users"].arn

  timeout       = 60
  memory        = 1024
  architectures = ["arm64"]

  environment_variables = {
    INACTIVE_DAYS                = 30
    ZITADEL_PRIVATE_KEY_SSM_PATH = aws_ssm_parameter.idp_cleanup_users_key_json.name
    ZITADEL_URL                  = "idp.${var.domain}"
    DRY_RUN                      = "false"
  }

  vpc = {
    subnet_ids         = module.idp_vpc.private_subnet_ids
    security_group_ids = [aws_security_group.idp_cleanup_users.id]
  }

  policies = [
    data.aws_iam_policy_document.idp_cleanup_users_get_ssm_parameters.json,
    data.aws_iam_policy_document.idp_cleanup_users_worker.json
  ]

  billing_tag_value = var.billing_tag_value
}

data "aws_iam_policy_document" "idp_cleanup_users_worker" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.idp_event_cleanup_users.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.sqs_dlq.arn]
  }
}

resource "aws_lambda_event_source_mapping" "idp_cleanup_users" {
  event_source_arn = aws_sqs_queue.idp_event_cleanup_users.arn
  function_name    = module.idp_cleanup_users.function_name
  batch_size       = 1
}