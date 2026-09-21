#
# Allows idp to send email using a SES SMTP server
#
resource "aws_ses_domain_identity" "idp" {
  count  = var.is_ses ? 1 : 0
  domain = aws_route53_zone.idp.name
}

resource "aws_ses_domain_dkim" "idp" {
  count  = var.is_ses ? 1 : 0
  domain = aws_ses_domain_identity.idp[0].domain
}

resource "aws_ses_domain_identity_verification" "ses_verif" {
  count      = var.is_ses ? 1 : 0
  domain     = aws_ses_domain_identity.idp[0].id
  depends_on = [aws_route53_record.idp_verification_TXT[0]]
}

resource "aws_iam_user" "idp_send_email" {
  count = var.is_ses ? 1 : 0
  name  = "idp_send_email"
  tags  = local.core_tags
}

data "aws_iam_policy_document" "idp_send_email" {
  count = var.is_ses ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "ses:SendRawEmail"
    ]
    resources = [
      aws_ses_domain_identity.idp[0].arn
    ]
  }
}

resource "aws_iam_policy" "idp_send_email" {
  count  = var.is_ses ? 1 : 0
  name   = "idp_send_email"
  policy = data.aws_iam_policy_document.idp_send_email[0].json
  tags   = local.core_tags
}

resource "aws_iam_group" "idp_send_email" {
  count = var.is_ses ? 1 : 0
  name  = "idp_send_email"
}

resource "aws_iam_group_policy_attachment" "idp_send_email" {
  count      = var.is_ses ? 1 : 0
  group      = aws_iam_group.idp_send_email[0].name
  policy_arn = aws_iam_policy.idp_send_email[0].arn
}

resource "aws_iam_user_group_membership" "idp_send_email" {
  count = var.is_ses ? 1 : 0
  user  = aws_iam_user.idp_send_email[0].name
  groups = [
    aws_iam_group.idp_send_email[0].name
  ]
}

resource "aws_iam_access_key" "idp_send_email" {
  count = var.is_ses ? 1 : 0
  user  = aws_iam_user.idp_send_email[0].name
}

moved {
  from = aws_ses_domain_identity.idp
  to   = aws_ses_domain_identity.idp[0]
}

moved {
  from = aws_ses_domain_dkim.idp
  to   = aws_ses_domain_dkim.idp[0]
}

moved {
  from = aws_ses_domain_identity_verification.ses_verif
  to   = aws_ses_domain_identity_verification.ses_verif[0]
}

moved {
  from = aws_iam_user.idp_send_email
  to   = aws_iam_user.idp_send_email[0]
}

moved {
  from = aws_iam_policy.idp_send_email
  to   = aws_iam_policy.idp_send_email[0]
}

moved {
  from = aws_iam_group.idp_send_email
  to   = aws_iam_group.idp_send_email[0]
}

moved {
  from = aws_iam_group_policy_attachment.idp_send_email
  to   = aws_iam_group_policy_attachment.idp_send_email[0]
}

moved {
  from = aws_iam_user_group_membership.idp_send_email
  to   = aws_iam_user_group_membership.idp_send_email[0]
}

moved {
  from = aws_iam_access_key.idp_send_email
  to   = aws_iam_access_key.idp_send_email[0]
}
