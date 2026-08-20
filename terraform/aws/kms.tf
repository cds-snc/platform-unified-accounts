#
# Encrypt messages sent to the CloudWatch alarm SNS topics
#
resource "aws_kms_key" "cloudwatch_alerts" {
  description         = "SNS topic for CloudWatch alarm alerts"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_cloudwatch.json

  tags = local.core_tags
}

data "aws_iam_policy_document" "kms_cloudwatch" {
  statement {
    sid       = "Enable IAM User Permissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "Allow_CloudWatch_for_CMK"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }

  statement {
    sid    = "CloudwatchEvents"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowLambdaForSQS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

#
# KMS key for Route53 DNSSEC signing
#
resource "aws_kms_key" "dnssec" {
  provider = aws.us-east-1

  count                    = var.env == "staging" ? 1 : 0
  description              = "KMS key for Route53 DNSSEC signing - auth.cdssandbox.xyz"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7
  enable_key_rotation      = false
  policy                   = data.aws_iam_policy_document.kms_dnssec.json

  tags = local.core_tags
}

data "aws_iam_policy_document" "kms_dnssec" {
  statement {
    sid       = "Enable IAM root permissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid    = "Allow Route53 DNSSEC to use the key"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:GetPublicKey",
      "kms:Sign",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid       = "Allow Route53 DNSSEC to create grants"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_kms_alias" "dnssec" {
  provider = aws.us-east-1

  count         = var.env == "staging" ? 1 : 0
  name          = "alias/auth-cdssandbox-xyz-dnssec"
  target_key_id = aws_kms_key.dnssec[0].key_id
}