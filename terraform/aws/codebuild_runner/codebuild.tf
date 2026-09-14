module "github_runner" {
  source = "github.com/cds-snc/terraform-modules//codebuild_github_runner?ref=5cbd7b59351373093c880fc73c41e6eef5cbdd99"

  project_name               = "platform-unified-accounts-user-portal"
  github_repository_url      = "https://github.com/cds-snc/platform-unified-accounts-user-portal.git"
  github_codeconnection_name = aws_codestarconnections_connection.github.name

  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids

  environment_variables = [{
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
