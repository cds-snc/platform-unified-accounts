module "idp_vpc" {
  source = "github.com/cds-snc/terraform-modules//vpc?ref=v11.4.5"
  name   = "idp-${var.env}"

  availability_zones               = local.vpc_az_count
  cidrsubnet_newbits               = 8
  single_nat_gateway               = true
  allow_https_request_out          = true
  allow_https_request_out_response = true
  allow_https_request_in           = true
  allow_https_request_in_response  = true
  enable_flow_log                  = false

  billing_tag_value = var.billing_tag_value
}

resource "aws_flow_log" "cloud_based_sensor" {
  log_destination      = "arn:aws:s3:::${var.cbs_satellite_bucket_name}/vpc_flow_logs/"
  log_destination_type = "s3"
  traffic_type         = "ALL"
  vpc_id               = module.idp_vpc.vpc_id
  log_format           = "$${vpc-id} $${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${subnet-id} $${instance-id}"
  tags                 = local.common_tags
}

#
# VPC endpoints
#

resource "aws_vpc_endpoint" "interface" {
  for_each = local.vpc_endpoints_interface

  vpc_id              = module.idp_vpc.vpc_id
  vpc_endpoint_type   = "Interface"
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  subnet_ids          = module.idp_vpc.private_subnet_ids
  tags                = local.common_tags
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = local.vpc_endpoints_gateway

  vpc_id            = module.idp_vpc.vpc_id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  route_table_ids   = module.idp_vpc.private_route_table_ids
  tags              = local.common_tags
}

moved {
  from = aws_vpc_endpoint.ssm
  to   = aws_vpc_endpoint.interface["ssm"]
}

#
# Network ACLs
#

resource "aws_network_acl_rule" "http_redirect" {
  network_acl_id = module.idp_vpc.main_nacl_id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "smtp_tls_outbound" {
  network_acl_id = module.idp_vpc.main_nacl_id
  rule_number    = 105
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 465
  to_port        = 465
}

resource "aws_network_acl_rule" "smtp_tls_inbound" {
  network_acl_id = module.idp_vpc.main_nacl_id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 465
  to_port        = 465
}

#
# Security groups
#

# VPC endpoint ================================================================
resource "aws_security_group" "vpc_endpoint" {
  name        = "vpc_endpoint"
  description = "NSG for VPC endpoints"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_idp_ecs" {
  description              = "Ingress from idp ECS task to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_idp_login_ecs" {
  description              = "Ingress from idp login ECS task to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.idp_login_ecs.id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_lambda_pr_review" {
  count = var.env == "staging" ? 1 : 0

  description              = "Ingress from lambda PR review env to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.lambda_pr_review[0].id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_idp_load_test_ecs" {
  count = var.env == "staging" ? 1 : 0

  description              = "Ingress from idp load test ECS task to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.idp_load_test_ecs[0].id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_idp_event_exporter" {
  description              = "Ingress from idp event exporter to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.idp_event_exporter.id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress_idp_cleanup_users" {
  description              = "Ingress from idp cleanup users Lambda to VPC endpoint"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint.id
  source_security_group_id = aws_security_group.idp_cleanup_users.id
}

# ECS IdP =====================================================================
resource "aws_security_group" "idp_ecs" {
  description = "NSG for idp ECS Tasks"
  name        = "idp_ecs"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_ecs_egress_endpoint_interface" {
  description              = "Egress from idp ecs to interface endpoints"
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

resource "aws_security_group_rule" "idp_ecs_egress_endpoint_gateway" {
  for_each = local.vpc_endpoints_gateway

  description       = "Egress from idp ecs to ${each.value} gateway endpoint"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_ecs.id
  prefix_list_ids   = [aws_vpc_endpoint.gateway[each.value].prefix_list_id]
}

resource "aws_security_group_rule" "idp_ecs_egress_smtp_tls" {
  description       = "Egress from idp ECS task to SMTP"
  type              = "egress"
  to_port           = 465
  from_port         = 465
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_ecs.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_ecs_egress_efs" {
  description              = "Egress from idp ECS task to EFS"
  type                     = "egress"
  to_port                  = 2049
  from_port                = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.idp_efs.id
}

resource "aws_security_group_rule" "idp_ecs_ingress_lb" {
  description              = "Ingress from load balancer to idp ECS task"
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.idp_lb.id
}

resource "aws_security_group_rule" "idp_ecs_ingress_idp_login_ecs" {
  description              = "Ingress from login ECS task to idp ECS task"
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.idp_login_ecs.id
}

# ECS IdP Login ===============================================================
resource "aws_security_group" "idp_login_ecs" {
  description = "NSG for idp login ECS Tasks"
  name        = "idp_login_ecs"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_login_ecs_ingress_lb" {
  description              = "Ingress from load balancer to idp login ECS task"
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_login_ecs.id
  source_security_group_id = aws_security_group.idp_lb.id
}

resource "aws_security_group_rule" "idp_login_ecs_egress_internet" {
  description       = "Egress from idp login ECS task to internet (HTTPS)"
  type              = "egress"
  to_port           = 443
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_login_ecs.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_login_ecs_egress_efs" {
  description              = "Egress from idp login ECS task to EFS"
  type                     = "egress"
  to_port                  = 2049
  from_port                = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_login_ecs.id
  source_security_group_id = aws_security_group.idp_efs.id
}

resource "aws_security_group_rule" "idp_login_ecs_egress_idp_ecs" {
  description              = "Egress from idp login ECS task to idp ECS task"
  type                     = "egress"
  to_port                  = 8080
  from_port                = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_login_ecs.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

# Load balancer ===============================================================
resource "aws_security_group" "idp_lb" {
  name        = "idp_lb"
  description = "NSG for idp load balancer"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_lb_ingress_internet_http" {
  description       = "Ingress from internet to load balancer (HTTP)"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_lb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_lb_ingress_internet_https" {
  description       = "Ingress from internet to load balancer (HTTPS)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_lb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_lb_egress_ecs" {
  description              = "Egress from load balancer to idp ECS task"
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_lb.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "idp_login_lb_egress_ecs" {
  description              = "Egress from load balancer to idp login ECS task"
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_lb.id
  source_security_group_id = aws_security_group.idp_login_ecs.id
}

# Database ====================================================================
resource "aws_security_group" "idp_db" {
  name        = "idp_db"
  description = "NSG for idp database"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_db_ingress_ecs" {
  description              = "Ingress to database from idp ECS task"
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_db.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "idp_ecs_egress_db" {
  description              = "Egress from idp ECS task to database"
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.idp_db.id
}

# EFS =======================================================================
resource "aws_security_group" "idp_efs" {
  name        = "idp_efs"
  description = "Allow access to EFS from idp ECS tasks"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_efs_ingress_ecs" {
  description              = "Allow NFS traffic from idp ECS tasks"
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_efs.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "idp_login_efs_ingress_ecs" {
  description              = "Allow NFS traffic from idp login ECS tasks"
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_efs.id
  source_security_group_id = aws_security_group.idp_login_ecs.id
}

# PR review environment =======================================================
resource "aws_security_group" "lambda_pr_review" {
  count = var.env == "staging" ? 1 : 0

  name        = "lambda-pr-review"
  description = "Lambda PR review environment"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "lambda_pr_review_egress_internet" {
  count = var.env == "staging" ? 1 : 0

  description       = "Egress lambda PR review env to the internet"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.lambda_pr_review[0].id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "lambda_pr_review_egress_idp_ecs" {
  count = var.env == "staging" ? 1 : 0

  description              = "Egress from lambda PR review env to idp ECS task"
  type                     = "egress"
  to_port                  = 8080
  from_port                = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda_pr_review[0].id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "idp_ecs_ingress_lambda_pr_review" {
  count = var.env == "staging" ? 1 : 0

  description              = "Ingress to idp ECS task from lambda PR review env"
  type                     = "ingress"
  to_port                  = 8080
  from_port                = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.lambda_pr_review[0].id
}

# IdP load test =======================================================
resource "aws_security_group" "idp_load_test_ecs" {
  count = var.env == "staging" ? 1 : 0

  name        = "idp-load-test-ecs"
  description = "IdP load test ECS task"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_load_test_ecs_egress_internet" {
  count = var.env == "staging" ? 1 : 0

  description       = "Egress from idp load test ECS task to internet (HTTPS)"
  type              = "egress"
  to_port           = 443
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_load_test_ecs[0].id
  cidr_blocks       = ["0.0.0.0/0"]
}

# IdP cleanup users ==========================================================
resource "aws_security_group" "idp_cleanup_users" {
  description = "NSG for idp cleanup users Lambda function"
  name        = "idp_cleanup_users"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_cleanup_users_egress_internal_lb" {
  description              = "Egress from idp cleanup users to idp internal load balancer"
  type                     = "egress"
  to_port                  = 443
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_cleanup_users.id
  source_security_group_id = aws_security_group.idp_internal_lb.id
}

resource "aws_security_group_rule" "idp_cleanup_users_egress_internet" {
  description       = "Egress from idp cleanup users to internet"
  type              = "egress"
  to_port           = 443
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_cleanup_users.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_cleanup_users_egress_s3" {
  description       = "Egress from idp cleanup users to S3"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_cleanup_users.id
  prefix_list_ids   = [aws_vpc_endpoint.gateway["s3"].prefix_list_id]
}

resource "aws_security_group_rule" "idp_cleanup_users_egress_vpc_endpoint" {
  description              = "Egress from idp cleanup users to VPC endpoint"
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_cleanup_users.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

# IdP event exporter ==========================================================
resource "aws_security_group" "idp_event_exporter" {
  description = "NSG for idp event exporter Lambda function"
  name        = "idp_event_exporter"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_event_exporter_egress_internal_lb" {
  description              = "Egress from idp event exporter to idp internal load balancer"
  type                     = "egress"
  to_port                  = 443
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_event_exporter.id
  source_security_group_id = aws_security_group.idp_internal_lb.id
}

resource "aws_security_group_rule" "idp_event_exporter_egress_internet" {
  description       = "Egress from idp event exporter to internet"
  type              = "egress"
  to_port           = 443
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_event_exporter.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "idp_event_exporter_egress_s3" {
  description       = "Egress from idp event exporter to S3"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_event_exporter.id
  prefix_list_ids   = [aws_vpc_endpoint.gateway["s3"].prefix_list_id]
}

resource "aws_security_group_rule" "idp_event_exporter_egress_vpc_endpoint" {
  description              = "Egress from idp event exporter to VPC endpoint"
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_event_exporter.id
  source_security_group_id = aws_security_group.vpc_endpoint.id
}

# Internal ALB ==========================================================
resource "aws_security_group" "idp_internal_lb" {
  description = "NSG for idp internal load balancer"
  name        = "idp_internal_lb"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.core_tags
}

resource "aws_security_group_rule" "idp_internal_lb_ingress_idp_cleanup_users" {
  description              = "Ingress from idp cleanup users Lambda to idp internal load balancer"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_internal_lb.id
  source_security_group_id = aws_security_group.idp_cleanup_users.id
}

resource "aws_security_group_rule" "idp_internal_lb_ingress_idp_event_exporter" {
  description              = "Ingress from idp event exporter Lambda to idp internal load balancer"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_internal_lb.id
  source_security_group_id = aws_security_group.idp_event_exporter.id
}

resource "aws_security_group_rule" "idp_internal_lb_ingress_clientvpn" {
  description              = "Ingress from client VPN to idp internal load balancer"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_internal_lb.id
  source_security_group_id = module.client_vpn.security_group_id
}

resource "aws_security_group_rule" "idp_internal_lb_egress_idp_ecs" {
  description              = "Egress from idp internal load balancer to idp ECS task"
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_internal_lb.id
  source_security_group_id = aws_security_group.idp_ecs.id
}

resource "aws_security_group_rule" "idp_ecs_ingress_internal_lb" {
  description              = "Ingress from idp internal load balancer to idp ECS task"
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.idp_ecs.id
  source_security_group_id = aws_security_group.idp_internal_lb.id
}
