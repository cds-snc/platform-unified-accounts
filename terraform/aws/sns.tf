#
# SNS topics
#
resource "aws_sns_topic" "cloudwatch_alert_warning" {
  name              = "cloudwatch-alert-warning"
  kms_master_key_id = aws_kms_key.cloudwatch_alerts.arn
  tags              = local.core_tags
}

resource "aws_sns_topic" "cloudwatch_alert_ok" {
  name              = "cloudwatch-alert-ok"
  kms_master_key_id = aws_kms_key.cloudwatch_alerts.arn
  tags              = local.core_tags
}

#
# SNS topic subscriptions
#
resource "aws_sns_topic_subscription" "cloudwatch_alert_warning" {
  topic_arn = aws_sns_topic.cloudwatch_alert_warning.arn
  protocol  = "https"
  endpoint  = var.cloudwatch_slack_webhook_url
}

resource "aws_sns_topic_subscription" "cloudwatch_alert_ok" {
  topic_arn = aws_sns_topic.cloudwatch_alert_ok.arn
  protocol  = "https"
  endpoint  = var.cloudwatch_slack_webhook_url
}

#
# Allow CloudWatch to use the SNS topics
#
resource "aws_sns_topic_policy" "cloudwatch_alert_warning" {
  arn    = aws_sns_topic.cloudwatch_alert_warning.arn
  policy = data.aws_iam_policy_document.cloudwatch_events_sns_topic.json
}

resource "aws_sns_topic_policy" "cloudwatch_alert_ok" {
  arn    = aws_sns_topic.cloudwatch_alert_ok.arn
  policy = data.aws_iam_policy_document.cloudwatch_events_sns_topic.json
}

data "aws_iam_policy_document" "cloudwatch_events_sns_topic" {
  statement {
    sid    = "SNS_Default_Policy"
    effect = "Allow"
    actions = [
      "SNS:Subscribe",
      "SNS:SetTopicAttributes",
      "SNS:RemovePermission",
      "SNS:Receive",
      "SNS:Publish",
      "SNS:ListSubscriptionsByTopic",
      "SNS:GetTopicAttributes",
      "SNS:DeleteTopic",
      "SNS:AddPermission",
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"

      values = [
        var.account_id,
      ]
    }

    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    sid    = "SNS_Publish_statement"
    effect = "Allow"
    actions = [
      "sns:Publish"
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}