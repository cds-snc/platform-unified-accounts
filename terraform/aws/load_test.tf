#
# ECS task definition to run k6 load tests against the IdP in staging.
#
module "load_test" {
  count  = var.env == "staging" ? 1 : 0
  source = "./load_test"
  region = var.region

  idp_url                   = "https://${var.domain}"
  idp_load_test_client_id   = var.idp_load_test_client_id
  idp_load_test_username    = var.idp_load_test_username
  idp_load_test_password    = var.idp_load_test_password
  idp_load_test_totp_secret = var.idp_load_test_totp_secret

  ecr_policy  = data.aws_ecr_lifecycle_policy_document.repo.json
  common_tags = local.common_tags
  core_tags   = local.core_tags
}
