#
# Creates a Codebuild project that manage self-hosted GitHub runners for our integration tests.
# This is required as our integrations tests need to interact with the private Zitadel API.
#
module "codebuild_runner" {
  count  = var.env == "staging" ? 1 : 0
  source = "./codebuild_runner"

  env                    = var.env
  github_runner_group_id = var.github_runner_group_id

  idp_vpc_id                  = module.idp_vpc.vpc_id
  idp_vpc_cidr_block          = module.idp_vpc.cidr_block
  idp_vpc_main_route_table_id = module.idp_vpc.main_route_table_id
  idp_alb_security_group_id   = aws_security_group.idp_internal_lb.id

  billing_tag_value = var.billing_tag_value
  common_tags       = local.common_tags
}
