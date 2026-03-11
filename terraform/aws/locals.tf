locals {
  cbs_satellite_bucket_arn = "arn:aws:s3:::${var.cbs_satellite_bucket_name}"
  vpc_az_count             = 2
  protocol_versions        = toset(["HTTP1", "HTTP2"])
  common_tags = {
    Terraform  = "true"
    CostCentre = var.billing_tag_value
  }
}