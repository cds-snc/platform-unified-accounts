resource "aws_sqs_queue" "idp_event_exporter_queue" {
  name                      = "idp-event-exporter-queue"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

resource "aws_sqs_queue" "idp_event_cleanup_users_queue" {
  name                      = "idp-event-cleanup-users-queue"
  kms_master_key_id         = aws_kms_key.sqs_dlq.arn
  message_retention_seconds = 1209600 # 14 days

  tags = local.core_tags
}

data "aws_iam_policy_document" "idp_event_exporter_queue_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.idp_event_exporter_queue.arn]
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
    resources = [aws_sqs_queue.idp_event_cleanup_users_queue.arn]
  }
}

resource "aws_sqs_queue_policy" "idp_event_exporter_queue_policy" {
  queue_url = aws_sqs_queue.idp_event_exporter_queue.id
  policy    = data.aws_iam_policy_document.idp_event_exporter_queue_policy.json
}

resource "aws_sqs_queue_policy" "idp_event_cleanup_users_queue_policy" {
  queue_url = aws_sqs_queue.idp_event_cleanup_users_queue.id
  policy    = data.aws_iam_policy_document.idp_event_cleanup_users_queue_policy.json
}