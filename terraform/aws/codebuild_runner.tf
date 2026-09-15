#
# Creates a Codebuild project that manage self-hosted GitHub runners for our integration tests.
# This is required as our integrations tests need to interact with the private Zitadel API.
#
module "codebuild_runner" {
  count  = var.env == "staging" ? 1 : 0
  source = "./codebuild_runner"

  vpc_id                 = module.idp_vpc.vpc_id
  subnet_ids             = module.idp_vpc.private_subnet_ids
  security_group_ids     = [aws_security_group.codebuild_github_runner[0].id]
  github_runner_group_id = var.github_runner_group_id

  billing_tag_value = var.billing_tag_value
  common_tags       = local.common_tags
}
