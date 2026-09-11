#
# Creates a Codebuild project that manage self-hosted GitHub runners for our integration tests.
# This is required as our integrations tests need to interact with the private Zitadel API.
#
module "codebuild_runner" {
  count  = var.env == "staging" ? 1 : 0
  source = "./codebuild_runner"

  common_tags = local.common_tags
}
