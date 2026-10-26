resource "aws_iam_role" "idp_login_pr" {
  name               = "idp-login-pr"
  assume_role_policy = data.aws_iam_policy_document.idp_login_pr.json
  tags               = var.core_tags
}

data "aws_iam_policy_document" "idp_login_pr" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "idp_login_pr_vpc_access" {
  role       = aws_iam_role.idp_login_pr.name
  policy_arn = aws_iam_policy.idp_login_pr_vpc_access.arn
}

resource "aws_iam_policy" "idp_login_pr_vpc_access" {
  name   = "idp-login-pr-vpc-access"
  path   = "/"
  policy = data.aws_iam_policy_document.idp_login_pr_vpc_access.json
  tags   = var.core_tags
}

data "aws_iam_policy_document" "idp_login_pr_vpc_access" {
  statement {
    sid    = "AWSLambdaVPCAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy_attachment" "idp_login_pr_ssm_params" {
  role       = aws_iam_role.idp_login_pr.name
  policy_arn = aws_iam_policy.idp_login_pr_ssm_params.arn
}

resource "aws_iam_policy" "idp_login_pr_ssm_params" {
  name   = "idp-login-pr-ssm-params"
  path   = "/"
  policy = data.aws_iam_policy_document.idp_login_pr_ssm_params.json
  tags   = var.core_tags
}

data "aws_iam_policy_document" "idp_login_pr_ssm_params" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      local.pr_review_env_ssm_param_arn
    ]
  }
}