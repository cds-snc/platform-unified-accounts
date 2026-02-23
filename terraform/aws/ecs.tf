locals {
  idp_container_env = [
    {
      "name"  = "ZITADEL_EXTERNALDOMAIN",
      "value" = var.domain
    },
    {
      "name"  = "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI"
      "value" = "https://${var.domain}/ui/v2/login"
    },
    {
      "name"  = "ZITADEL_OIDC_DEFAULTLOGINURLV2"
      "value" = "https://${var.domain}/ui/v2/login/login?authRequest="
    },
    {
      "name"  = "ZITADEL_OIDC_DEFAULTLOGOUTURLV2"
      "value" = "https://${var.domain}/ui/v2/login/logout?post_logout_redirect="
    },
    {
      "name"  = "ZITADEL_SAML_DEFAULTLOGINURLV2"
      "value" = "https://${var.domain}/ui/v2/login/login?samlRequest="
    },
  ]
  idp_container_secrets = [
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_DATABASE"
      "valueFrom" = aws_ssm_parameter.idp_database.arn
    },
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_HOST"
      "valueFrom" = aws_ssm_parameter.idp_database_host.arn
    },
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_USER_USERNAME"
      "valueFrom" = aws_ssm_parameter.idp_database_username.arn
    },
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD"
      "valueFrom" = aws_ssm_parameter.idp_database_password.arn
    },
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME"
      "valueFrom" = aws_ssm_parameter.idp_database_admin_username.arn
    },
    {
      "name"      = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"
      "valueFrom" = aws_ssm_parameter.idp_database_admin_password.arn
    },
    {
      "name"      = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME"
      "valueFrom" = aws_ssm_parameter.idp_admin_username.arn
    },
    {
      "name"      = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD"
      "valueFrom" = aws_ssm_parameter.idp_admin_password.arn
    },
    {
      "name"      = "ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_USERNAME"
      "valueFrom" = aws_ssm_parameter.idp_loginclient_machine_username.arn
    },
    {
      "name"      = "ZITADEL_MASTERKEY"
      "valueFrom" = aws_ssm_parameter.idp_secret_key.arn
    },
  ]

  login_container_env = [
    {
      "name"  = "ZITADEL_API_URL",
      "value" = "https://${var.domain}"
    },
    {
      "name"  = "NEXT_PUBLIC_BASE_PATH",
      "value" = "/ui/v2/login"
    },
    {
      "name"  = "ZITADEL_SERVICE_USER_TOKEN_FILE",
      "value" = "/idp/login-client.pat"
    },
    {
      "name"  = "CUSTOM_REQUEST_HEADERS",
      "value" = "Host:${var.domain}"
    },
  ]
}

module "idp_ecs" {
  source = "github.com/cds-snc/terraform-modules//ecs?ref=v10.11.0"

  cluster_name     = "idp"
  service_name     = "idp"
  task_cpu         = var.idp_task_cpu
  task_memory      = var.idp_task_memory
  cpu_architecture = "ARM64"

  cluster_capacity_provider      = var.idp_cluster_capacity_provider
  service_use_latest_task_def    = true
  container_image_track_deployed = true

  # Scaling
  enable_autoscaling       = true
  desired_count            = var.idp_task_desired_count
  autoscaling_min_capacity = var.idp_task_min_capacity
  autoscaling_max_capacity = var.idp_task_max_capacity

  # Task definition
  container_image                     = "${aws_ecr_repository.idp.repository_url}:latest"
  container_command                   = ["start-from-init", "--masterkeyFromEnv", "--tlsMode", "enabled", "--config", "/app/config.yaml", "--steps", "/app/steps.yaml"]
  container_host_port                 = 8080
  container_port                      = 8080
  container_environment               = local.idp_container_env
  container_secrets                   = local.idp_container_secrets
  container_read_only_root_filesystem = false

  task_exec_role_policy_documents = [
    data.aws_iam_policy_document.ecs_task_ssm_parameters.json,
  ]

  task_role_policy_documents = [
    data.aws_iam_policy_document.efs_write.json
  ]

  container_mount_points = [{
    sourceVolume  = "idp-data"
    containerPath = "/idp"
    readOnly      = false
  }]

  task_volume = [{
    name = "idp-data"
    efs_volume_configuration = {
      file_system_id          = aws_efs_file_system.idp.id
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2049
      authorization_config = {
        access_point_id = aws_efs_access_point.idp.id
        iam             = "ENABLED"
      }
    }
  }]

  lb_target_group_arns = [
    for protocol_version in local.protocol_versions : {
      target_group_arn = aws_lb_target_group.idp[protocol_version].arn
      container_name   = "idp"
      container_port   = 8080
    }
  ]
  subnet_ids         = module.idp_vpc.private_subnet_ids
  security_group_ids = [aws_security_group.idp_ecs.id]

  billing_tag_value = var.billing_tag_value

  depends_on = [
    module.idp_database
  ]
}

module "login_ecs" {
  source = "github.com/cds-snc/terraform-modules//ecs?ref=v10.11.0"

  create_cluster   = false
  cluster_name     = "idp"
  service_name     = "idp-login"
  task_cpu         = var.idp_login_task_cpu
  task_memory      = var.idp_login_task_memory
  cpu_architecture = "ARM64"

  service_use_latest_task_def    = true
  container_image_track_deployed = true

  # Scaling
  enable_autoscaling       = true
  desired_count            = var.idp_login_task_desired_count
  autoscaling_min_capacity = var.idp_login_task_min_capacity
  autoscaling_max_capacity = var.idp_login_task_max_capacity

  # Task definition
  container_image                     = "${aws_ecr_repository.idp_login.repository_url}:latest"
  container_host_port                 = 3000
  container_port                      = 3000
  container_environment               = local.login_container_env
  container_read_only_root_filesystem = false

  task_exec_role_policy_documents = [
    data.aws_iam_policy_document.ecs_task_ssm_parameters.json,
  ]

  task_role_policy_documents = [
    data.aws_iam_policy_document.efs_write.json,
    data.aws_iam_policy_document.ecs_task_create_tunnel.json
  ]

  enable_execute_command = true

  container_mount_points = [{
    sourceVolume  = "idp-data"
    containerPath = "/idp"
    readOnly      = false
  }]

  task_volume = [{
    name = "idp-data"
    efs_volume_configuration = {
      file_system_id          = aws_efs_file_system.idp.id
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2049
      authorization_config = {
        access_point_id = aws_efs_access_point.idp.id
        iam             = "ENABLED"
      }
    }
  }]

  lb_target_group_arn = aws_lb_target_group.idp_login.arn
  subnet_ids          = module.idp_vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.idp_login_ecs.id]

  billing_tag_value = var.billing_tag_value

  depends_on = [
    module.idp_ecs
  ]
}

#
# IAM policies
#
data "aws_iam_policy_document" "ecs_task_ssm_parameters" {
  statement {
    sid    = "GetSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.idp_admin_username.arn,
      aws_ssm_parameter.idp_admin_password.arn,
      aws_ssm_parameter.idp_database.arn,
      aws_ssm_parameter.idp_database_host.arn,
      aws_ssm_parameter.idp_database_username.arn,
      aws_ssm_parameter.idp_database_password.arn,
      aws_ssm_parameter.idp_database_admin_username.arn,
      aws_ssm_parameter.idp_database_admin_password.arn,
      aws_ssm_parameter.idp_loginclient_machine_username.arn,
      aws_ssm_parameter.idp_secret_key.arn
    ]
  }
}

data "aws_iam_policy_document" "efs_write" {
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:DescribeMountTargets",
    ]
    resources = [
      aws_efs_file_system.idp.arn
    ]
  }
}

data "aws_iam_policy_document" "ecs_task_create_tunnel" {
  statement {
    sid    = "CreateSSMTunnel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel"
    ]
    resources = ["*"]
  }
}

#
# SSM Parameters
#
resource "aws_ssm_parameter" "idp_secret_key" {
  name  = "idp_secret_key"
  type  = "SecureString"
  value = var.idp_secret_key
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_admin_username" {
  name  = "idp_admin_username"
  type  = "SecureString"
  value = var.idp_admin_username
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_admin_password" {
  name  = "idp_admin_password"
  type  = "SecureString"
  value = var.idp_admin_password
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "idp_loginclient_machine_username" {
  name  = "idp_loginclient_machine_username"
  type  = "SecureString"
  value = var.idp_loginclient_machine_username
  tags  = local.common_tags
}
