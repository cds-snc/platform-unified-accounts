#
# Stream CloudWatch logs to S3 for long-term storage
#
module "cloudwatch_log_storage" {
  source = "github.com/cds-snc/terraform-modules//cloudwatch_log_storage?ref=v11.4.1"

  product_name          = var.product_name
  athena_workgroup_name = module.athena_access_logs.athena_workgroup_name
  athena_database_name  = module.athena_access_logs.athena_database_name
  log_expiration_days   = 730

  cloudwatch_log_group_names = [
    module.idp_ecs.cloudwatch_log_group_name,
    module.login_ecs.cloudwatch_log_group_name,
    module.event_exporter_lambda.lambda_function_cloudwatch_log_group_name
  ]

  billing_tag_value = var.billing_tag_value
}
