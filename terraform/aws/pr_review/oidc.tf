locals {
  pr_review_delete_unused     = "platform-unified-accounts-user-portal-pr-review-delete-unused"
  pr_review_deploy            = "platform-unified-accounts-user-portal-pr-review-deploy"
  pr_review_get_vars          = "platform-unified-accounts-pr-review-get-vars"
  pr_review_env_ssm_param_arn = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/idp-login-pr/env"
}

#
# Create the OIDC roles used by the GitHub workflows
# The roles can be assumed by the GitHub workflows according to the `claim`
# attribute of each role.
# 
module "github_workflow_roles" {
  source = "github.com/cds-snc/terraform-modules//gh_oidc_role?ref=v11.4.5"

  roles = [
    {
      name      = local.pr_review_delete_unused
      repo_name = "platform-unified-accounts-user-portal"
      claim     = "ref:refs/heads/main"
    },
    {
      name      = local.pr_review_deploy
      repo_name = "platform-unified-accounts-user-portal"
      claim     = "pull_request"
    },
    {
      name      = local.pr_review_get_vars
      repo_name = "platform-unified-accounts"
      claim     = "ref:refs/heads/main"
    }
  ]

  billing_tag_value = var.billing_tag_value
}

#
# Create and Manage PR review environment resources
#
resource "aws_iam_role_policy_attachment" "pr_review_deploy" {
  role       = local.pr_review_deploy
  policy_arn = aws_iam_policy.pr_review_deploy.arn

  depends_on = [module.github_workflow_roles]
}

resource "aws_iam_policy" "pr_review_deploy" {
  name   = local.pr_review_deploy
  path   = "/"
  policy = data.aws_iam_policy_document.pr_review_deploy.json
  tags   = var.core_tags
}

#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "pr_review_deploy" {
  statement {
    effect = "Allow"
    actions = [
      "lambda:AddPermission",
      "lambda:CreateFunction",
      "lambda:CreateFunctionUrlConfig",
      "lambda:DeleteFunction",
      "lambda:DeleteFunctionUrlConfig",
      "lambda:DeleteFunctionConcurrency",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionUrlConfig",
      "lambda:ListFunctionUrlConfigs",
      "lambda:PutFunctionConcurrency",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:UpdateFunctionUrlConfig"
    ]
    resources = [
      "arn:aws:lambda:${var.region}:${var.account_id}:function:idp-login-pr-*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      aws_iam_role.idp_login_pr.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups"
    ]
    resources = [
      "*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DeleteLogGroup",
      "logs:DeleteLogStream",
      "logs:DeleteRetentionPolicy",
      "logs:DescribeLogStreams",
      "logs:PutRetentionPolicy"
    ]
    resources = [
      "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/idp-login-pr-*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchDeleteImage",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [
      aws_ecr_repository.idp_login_pr.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs"
    ]
    resources = ["*"]
  }
}

#
# Delete unused PR review environment resources
#
resource "aws_iam_role_policy_attachment" "pr_review_delete_unused" {
  role       = local.pr_review_delete_unused
  policy_arn = aws_iam_policy.pr_review_delete_unused.arn

  depends_on = [module.github_workflow_roles]
}

resource "aws_iam_policy" "pr_review_delete_unused" {
  name   = local.pr_review_delete_unused
  path   = "/"
  policy = data.aws_iam_policy_document.pr_review_delete_unused.json
  tags   = var.core_tags
}

#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "pr_review_delete_unused" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchDeleteImage",
      "ecr:ListImages",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${var.account_id}:repository/idp-login-pr"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "lambda:ListFunctions"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "lambda:DeleteFunction",
      "lambda:DeleteFunctionUrlConfig",
      "lambda:DeleteFunctionConcurrency",
    ]
    resources = [
      "arn:aws:lambda:${var.region}:${var.account_id}:function:idp-login-pr-*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups"
    ]
    resources = [
      "*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:DeleteLogGroup",
      "logs:DeleteLogStream",
      "logs:DeleteRetentionPolicy",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/idp-login-pr-*"
    ]
  }
}

#
# Get env vars from IdP login task definition for PR review environments
#
resource "aws_iam_role_policy_attachment" "pr_review_get_vars" {
  role       = local.pr_review_get_vars
  policy_arn = aws_iam_policy.pr_review_get_vars.arn

  depends_on = [module.github_workflow_roles]
}

resource "aws_iam_policy" "pr_review_get_vars" {
  name   = local.pr_review_get_vars
  path   = "/"
  policy = data.aws_iam_policy_document.pr_review_get_vars.json
  tags   = var.core_tags
}

data "aws_iam_policy_document" "pr_review_get_vars" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:ListTasks"
    ]
    resources = [
      "arn:aws:ecs:${var.region}:${var.account_id}:container-instance/idp/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeTasks"
    ]
    resources = [
      "arn:aws:ecs:${var.region}:${var.account_id}:cluster/idp",
      "arn:aws:ecs:${var.region}:${var.account_id}:task/idp/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition"
    ]
    resources = [
      "*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = concat(
      var.pr_review_env_ssm_params_get,
      [local.pr_review_env_ssm_param_arn]
    )
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:PutParameter"
    ]
    resources = [
      local.pr_review_env_ssm_param_arn
    ]
  }
}