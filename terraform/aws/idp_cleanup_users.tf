/*
 * Lambda function to cleanup users
 */
module "idp_cleanup_users_lambda" {
  source = "github.com/cds-snc/terraform-modules//lambda_schedule?ref=v11.3.6"

  lambda_name                = "idp-cleanup-users"
  lambda_schedule_expression = "cron(0 0 * * ? *)" # Run every day at midnight UTC
  lambda_timeout             = "60"
  lambda_architectures       = ["arm64"]
  lambda_ecr_arn             = aws_ecr_repository.repo["idp-cleanup-users"].arn
  lambda_image_uri           = aws_ecr_repository.repo["idp-cleanup-users"].repository_url

  lambda_policies = [
    data.aws_iam_policy_document.idp_cleanup_users_get_ssm_parameters.json
  ]

  lambda_environment_variables = {
    INACTIVE_DAYS          = 30
    ZITADEL_HOST           = var.domain
    ZITADEL_TOKEN_SSM_PATH = aws_ssm_parameter.idp_cleanup_users_bearer_token.name
    ZITADEL_URL            = "http://idp.${aws_service_discovery_private_dns_namespace.idp_ecs.name}:8080"
    DRY_RUN                = "false"
  }

  lambda_vpc_config = {
    subnet_ids         = module.idp_vpc.private_subnet_ids
    security_group_ids = [aws_security_group.idp_cleanup_users.id]
  }

  create_ecr_repository = false
  billing_tag_value     = var.billing_tag_value
}

data "aws_iam_policy_document" "idp_cleanup_users_get_ssm_parameters" {
  statement {
    sid    = "GetSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.idp_cleanup_users_bearer_token.arn,
    ]
  }
}

resource "aws_ssm_parameter" "idp_cleanup_users_bearer_token" {
  name  = "idp_cleanup_users_bearer_token"
  type  = "SecureString"
  value = var.idp_cleanup_users_bearer_token
  tags  = local.core_tags
}
