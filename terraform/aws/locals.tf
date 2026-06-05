locals {
  cbs_satellite_bucket_arn = "arn:aws:s3:::${var.cbs_satellite_bucket_name}"
  vpc_az_count             = 2
  protocol_versions        = toset(["HTTP1", "HTTP2"])
  vpc_endpoints_interface  = toset(["ecr.api", "ecr.dkr", "logs", "monitoring", "rds", "ssm"])
  vpc_endpoints_gateway    = toset(["s3"])

  common_tags = {
    Terraform  = "true"
    CostCentre = var.billing_tag_value
    ssc_cbrid  = "22DI"
  }

  core_tags = merge(local.common_tags, {
    ssc_cbrid = "22DH"
  })
}