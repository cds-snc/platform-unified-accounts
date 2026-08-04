#
# DynamoDB table used by the login portal for application-layer rate limiting.
# The table tracks submission counts per IP within a fixed time window so that
# the portal can enforce a secondary limit independently of the WAF rules.
#
resource "aws_dynamodb_table" "contact_us_rate_limit" {
  name         = "contact-us-rate-limit-${var.env}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk" # Format: "{ip}#{window_minute}"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.core_tags
}

data "aws_iam_policy_document" "contact_us_rate_limit" {
  statement {
    sid    = "ContactUsRateLimit"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.contact_us_rate_limit.arn,
    ]
  }
}
