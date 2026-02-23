#
# RDS Postgres cluster
#
module "idp_database" {
  source = "github.com/cds-snc/terraform-modules//rds?ref=v10.11.0"
  name   = "idp-${var.env}"

  database_name           = var.idp_database
  engine                  = "aurora-postgresql"
  engine_version          = "17.7"
  instances               = var.idp_database_instance_count
  instance_class          = "db.serverless"
  serverless_min_capacity = var.idp_database_min_acu
  serverless_max_capacity = var.idp_database_max_acu

  username  = var.idp_database_admin_username
  password  = var.idp_database_admin_password
  use_proxy = false

  # Enable audit logging to CloudWatch
  db_cluster_parameter_group_name          = aws_rds_cluster_parameter_group.idp.name
  enabled_cloudwatch_logs_exports          = ["postgresql"]
  cloudwatch_log_exports_retention_in_days = 365

  backup_retention_period      = 14
  preferred_backup_window      = "02:00-04:00"
  performance_insights_enabled = false

  vpc_id             = module.idp_vpc.vpc_id
  subnet_ids         = module.idp_vpc.private_subnet_ids
  security_group_ids = [aws_security_group.idp_db.id]

  billing_tag_value = var.billing_tag_value
}

resource "aws_rds_cluster_parameter_group" "idp" {
  name        = "idp-db-pg-audit"
  family      = "aurora-postgresql17"
  description = "RDS parameter group that enables pgAudit"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit,pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "pgaudit.log"
    value        = "role,write,ddl"
    apply_method = "pending-reboot"
  }

  tags = local.common_tags
}

resource "aws_ssm_parameter" "idp_database" {
  name  = "idp_database"
  type  = "SecureString"
  value = var.idp_database
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_database_host" {
  name  = "idp_database_host"
  type  = "SecureString"
  value = module.idp_database.rds_cluster_endpoint
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_database_username" {
  name  = "idp_database_username"
  type  = "SecureString"
  value = var.idp_database_username
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_database_password" {
  name  = "idp_database_password"
  type  = "SecureString"
  value = var.idp_database_password
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_database_admin_username" {
  name  = "idp_database_admin_username"
  type  = "SecureString"
  value = var.idp_database_admin_username
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_database_admin_password" {
  name  = "idp_database_admin_password"
  type  = "SecureString"
  value = var.idp_database_admin_password
  tags  = local.common_tags
}
