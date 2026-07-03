module "pr_review" {
  count  = var.env == "staging" ? 1 : 0
  source = "./pr_review"

  region     = var.region
  account_id = var.account_id

  pr_review_env_ssm_params_get = [
    aws_ssm_parameter.idp_loginclient_machine_username.arn,
    aws_ssm_parameter.idp_loginclient_pat.arn,
    aws_ssm_parameter.idp_zitadel_org.arn,
    aws_ssm_parameter.idp_notify_api_key.arn,
    aws_ssm_parameter.idp_notify_template_id.arn,
  ]

  ecr_policy        = data.aws_ecr_lifecycle_policy_document.repo.json
  billing_tag_value = var.billing_tag_value
  common_tags       = local.common_tags
  core_tags         = local.core_tags
}
