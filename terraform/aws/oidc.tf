locals {
  docker_push   = "platform-unified-accounts-docker-push"
  docker_deploy = "platform-unified-accounts-docker-deploy"
}

module "github_deploy_workflow_roles" {
  source = "github.com/cds-snc/terraform-modules//gh_oidc_role?ref=v11.4.5"

  roles = [
    {
      name      = local.docker_push
      repo_name = "platform-unified-accounts"
      claim     = "ref:refs/heads/main"
    },
    {
      name      = local.docker_deploy
      repo_name = "platform-unified-accounts"
      claim     = "ref:refs/heads/main"
    },
  ]

  billing_tag_value = var.billing_tag_value
}

resource "aws_iam_role_policy_attachment" "docker_push" {
  role       = local.docker_push
  policy_arn = aws_iam_policy.docker_push.arn

  depends_on = [module.github_deploy_workflow_roles]
}

resource "aws_iam_policy" "docker_push" {
  name   = local.docker_push
  path   = "/"
  policy = data.aws_iam_policy_document.docker_push.json
  tags   = local.core_tags
}

#trivy:ignore:AVD-AWS-0342
data "aws_iam_policy_document" "docker_push" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      aws_ecr_repository.repo["alarms-slack"].arn,
      aws_ecr_repository.repo["idp"].arn,
      aws_ecr_repository.repo["idp-cleanup-users"].arn,
      aws_ecr_repository.repo["idp-event-exporter"].arn,
      aws_ecr_repository.repo["idp-login"].arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy_attachment" "docker_deploy" {
  role       = local.docker_deploy
  policy_arn = aws_iam_policy.docker_deploy.arn

  depends_on = [module.github_deploy_workflow_roles]
}

resource "aws_iam_policy" "docker_deploy" {
  name   = local.docker_deploy
  path   = "/"
  policy = data.aws_iam_policy_document.docker_deploy.json
  tags   = local.core_tags
}

#trivy:ignore:AVD-AWS-0342
data "aws_iam_policy_document" "docker_deploy" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [
      "arn:aws:ecs:${var.region}:${var.account_id}:cluster/idp",
      "arn:aws:ecs:${var.region}:${var.account_id}:service/idp/idp",
      "arn:aws:ecs:${var.region}:${var.account_id}:service/idp/idp-login",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      module.idp_ecs.task_exec_role_arn,
      module.idp_ecs.task_role_arn,
      module.login_ecs.task_exec_role_arn,
      module.login_ecs.task_role_arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
    ]
    resources = [
      "arn:aws:lambda:${var.region}:${var.account_id}:function:alarms-slack",
      "arn:aws:lambda:${var.region}:${var.account_id}:function:idp-cleanup-users",
      "arn:aws:lambda:${var.region}:${var.account_id}:function:idp-event-exporter",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/ecs/idp/*",
    ]
  }
}
