resource "aws_sqs_queue" "idp_event_exporter_dlq_queue" {
  name                      = "idp-event-exporter-dlq"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

moved {
  from = aws_sqs_queue.idp_event_exporter_queue
  to   = aws_sqs_queue.idp_event_exporter_dlq_queue
}

resource "aws_sqs_queue" "idp_event_cleanup_users_dlq_queue" {
  name                      = "idp-event-cleanup-dlq"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

moved {
  from = aws_sqs_queue.idp_event_cleanup_users_queue
  to   = aws_sqs_queue.idp_event_cleanup_users_dlq_queue
}

data "aws_iam_policy_document" "idp_event_exporter_queue_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_exporter_dlq_queue.arn]
  }
}

data "aws_iam_policy_document" "idp_event_cleanup_users_queue_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_cleanup_users_dlq_queue.arn]
  }
}

resource "aws_sqs_queue_policy" "idp_event_exporter_queue_policy" {
  queue_url = aws_sqs_queue.idp_event_exporter_dlq_queue.id
  policy    = data.aws_iam_policy_document.idp_event_exporter_queue_policy.json
}

resource "aws_sqs_queue_policy" "idp_event_cleanup_users_queue_policy" {
  queue_url = aws_sqs_queue.idp_event_cleanup_users_dlq_queue.id
  policy    = data.aws_iam_policy_document.idp_event_cleanup_users_queue_policy.json
}

locals {
  dlq_redrive_schedules = {
    idp_event_exporter = {
      dlq_arn                 = aws_sqs_queue.idp_event_exporter_dlq_queue.arn
      destination_queue_arn   = aws_sqs_queue.idp_event_exporter.arn
      schedule_expression     = "rate(1 hour)"
      max_messages_per_second = 10
    }

    idp_cleanup_users = {
      dlq_arn                 = aws_sqs_queue.idp_event_cleanup_users_dlq_queue.arn
      destination_queue_arn   = aws_sqs_queue.idp_event_cleanup_users.arn
      schedule_expression     = "rate(1 hour)"
      max_messages_per_second = 10
    }
  }
}

data "aws_iam_policy_document" "dlq_redrive_scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlq_redrive_scheduler" {
  name               = "dlq-redrive-scheduler"
  assume_role_policy = data.aws_iam_policy_document.dlq_redrive_scheduler_assume.json
  tags               = local.core_tags
}

data "aws_iam_policy_document" "dlq_redrive_scheduler" {
  statement {
    sid    = "DlqMoveTask"
    effect = "Allow"
    actions = [
      "sqs:StartMessageMoveTask",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [for config in values(local.dlq_redrive_schedules) : config.dlq_arn]
  }

  statement {
    sid       = "SendToDestinationQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [for config in values(local.dlq_redrive_schedules) : config.destination_queue_arn]
  }

  statement {
    sid    = "KmsForRedrivenMessages"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.sqs_dlq.arn]
  }
}

resource "aws_iam_role_policy" "dlq_redrive_scheduler" {
  name   = "dlq-redrive-scheduler"
  role   = aws_iam_role.dlq_redrive_scheduler.id
  policy = data.aws_iam_policy_document.dlq_redrive_scheduler.json
}

resource "aws_scheduler_schedule" "dlq_redrive" {
  for_each = local.dlq_redrive_schedules

  name                = "${replace(each.key, "_", "-")}-dlq-redrive"
  schedule_expression = each.value.schedule_expression
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:sqs:startMessageMoveTask"
    role_arn = aws_iam_role.dlq_redrive_scheduler.arn

    input = jsonencode({
      SourceArn                    = each.value.dlq_arn
      DestinationArn               = each.value.destination_queue_arn
      MaxNumberOfMessagesPerSecond = each.value.max_messages_per_second
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}