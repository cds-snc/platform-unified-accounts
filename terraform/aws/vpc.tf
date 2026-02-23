module "idp_vpc" {
  source = "github.com/cds-snc/terraform-modules//vpc?ref=v10.11.0"
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

# ECS IdP
resource "aws_security_group" "idp_ecs" {
  description = "NSG for idp ECS Tasks"
  name        = "idp_ecs"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.common_tags
}

resource "aws_security_group_rule" "idp_ecs_egress_internet" {
  description       = "Egress from idp ECS task to internet (HTTPS)"
  type              = "egress"
  to_port           = 443
  from_port         = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.idp_ecs.id
  cidr_blocks       = ["0.0.0.0/0"]
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

# ECS IdP Login
resource "aws_security_group" "idp_login_ecs" {
  description = "NSG for idp login ECS Tasks"
  name        = "idp_login_ecs"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.common_tags
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

# Load balancer
resource "aws_security_group" "idp_lb" {
  name        = "idp_lb"
  description = "NSG for idp load balancer"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.common_tags
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

# Database
resource "aws_security_group" "idp_db" {
  name        = "idp_db"
  description = "NSG for idp database"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.common_tags
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

# EFS
resource "aws_security_group" "idp_efs" {
  name        = "idp_efs"
  description = "Allow access to EFS from idp ECS tasks"
  vpc_id      = module.idp_vpc.vpc_id
  tags        = local.common_tags
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