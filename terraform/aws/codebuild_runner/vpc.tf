#
# Dedicated VPC for CodeBuild GitHub runner
# This is being done to limit the exposure of the IdP and its private resources 
#
module "codebuild_vpc" {
  source = "github.com/cds-snc/terraform-modules//vpc?ref=v11.4.7"
  name   = "codebuild-${var.env}"
  cidr   = "10.1.0.0/22"

  availability_zones               = 2
  cidrsubnet_newbits               = 2
  single_nat_gateway               = true
  allow_https_request_out          = true
  allow_https_request_out_response = true
  allow_https_request_in           = true
  allow_https_request_in_response  = true
  enable_flow_log                  = true

  billing_tag_value = var.billing_tag_value
}

#
# VPC peering connection
#
resource "aws_vpc_peering_connection" "idp_codebuild" {
  vpc_id        = var.idp_vpc_id
  peer_vpc_id   = module.codebuild_vpc.vpc_id
  auto_accept   = true

  tags = var.common_tags
}

resource "aws_route" "idp_to_codebuild" {
  route_table_id            = var.idp_vpc_main_route_table_id
  destination_cidr_block    = module.codebuild_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.idp_codebuild.id
}

resource "aws_route" "codebuild_to_idp" {
  route_table_id            = module.codebuild_vpc.main_route_table_id
  destination_cidr_block    = var.idp_vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.idp_codebuild.id
}

#
# Security group
#
resource "aws_security_group" "codebuild_github_runner" {
  description = "NSG for CodeBuild GitHub runner"
  name        = "codebuild_github_runner"
  vpc_id      = module.codebuild_vpc.vpc_id
  tags        = var.common_tags
}

resource "aws_security_group_rule" "codebuild_github_runner_egress_internet" {
  description       = "Egress from CodeBuild GitHub runner to the internet"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.codebuild_github_runner.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_internal_lb_ingress_codebuild_github_runner" {
  description              = "Ingress from CodeBuild GitHub runner to idp internal load balancer"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = var.idp_alb_security_group_id
  source_security_group_id = aws_security_group.codebuild_github_runner.id
}
