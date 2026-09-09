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