#
# Allows idp to send email using a SES SMTP server
#
resource "aws_ses_domain_identity" "idp" {
  domain = aws_route53_zone.idp.name
}

resource "aws_ses_domain_dkim" "idp" {
  domain = aws_ses_domain_identity.idp.domain
}

resource "aws_ses_domain_identity_verification" "ses_verif" {
  domain     = aws_ses_domain_identity.idp.id
  depends_on = [aws_route53_record.idp_verification_TXT]
}

resource "aws_iam_user" "idp_send_email" {
  name = "idp_send_email"
  tags = local.core_tags
}

data "aws_iam_policy_document" "idp_send_email" {
  statement {
    effect = "Allow"
    actions = [
      "ses:SendRawEmail"
    ]
    resources = [
      aws_ses_domain_identity.idp.arn
    ]
  }
}

resource "aws_iam_policy" "idp_send_email" {
  name   = "idp_send_email"
  policy = data.aws_iam_policy_document.idp_send_email.json
  tags   = local.core_tags
}

resource "aws_iam_group" "idp_send_email" {
  name = "idp_send_email"
}

resource "aws_iam_group_policy_attachment" "idp_send_email" {
  group      = aws_iam_group.idp_send_email.name
  policy_arn = aws_iam_policy.idp_send_email.arn
}

resource "aws_iam_user_group_membership" "idp_send_email" {
  user = aws_iam_user.idp_send_email.name
  groups = [
    aws_iam_group.idp_send_email.name
  ]
}

resource "aws_iam_access_key" "idp_send_email" {
  user = aws_iam_user.idp_send_email.name
}
