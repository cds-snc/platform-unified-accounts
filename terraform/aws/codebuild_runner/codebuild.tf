module "github_runner" {
  source = "github.com/cds-snc/terraform-modules//codebuild_github_runner?ref=v12.1.2"

  project_name               = "platform-unified-accounts-user-portal"
  github_repository_url      = "https://github.com/cds-snc/platform-unified-accounts-user-portal.git"
  github_codeconnection_name = aws_codestarconnections_connection.github.name
  privileged_mode            = true

  vpc_id             = module.codebuild_vpc.vpc_id
  subnet_ids         = module.codebuild_vpc.private_subnet_ids
  security_group_ids = [aws_security_group.codebuild_github_runner.id]

  environment_variables = [{
    name  = "CODEBUILD_CONFIG_GITHUB_ACTIONS_ORG_REGISTRATION_NAME"
    value = "cds-snc"
    }, {
    name  = "CODEBUILD_CONFIG_GITHUB_ACTIONS_RUNNER_GROUP_ID"
    value = var.github_runner_group_id
  }]

  billing_tag_value = var.billing_tag_value
}

resource "aws_codestarconnections_connection" "github" {
  name          = "github-runner-connection"
  provider_type = "GitHub"
  tags          = var.common_tags
}
