locals {
  idp_load_test_container_env = [
    {
      "name"  = "ZITADEL_URL",
      "value" = var.idp_url
    },
    {
      "name"  = "REDIRECT_URI",
      "value" = "http://localhost/auth/callback"
    },
  ]
  idp_load_test_container_secrets = [
    {
      "name"      = "CLIENT_ID",
      "valueFrom" = aws_ssm_parameter.idp_load_test_client_id.arn
    },
    {
      "name"      = "TEST_USERNAME",
      "valueFrom" = aws_ssm_parameter.idp_load_test_username.arn
    },
    {
      "name"      = "TEST_PASSWORD",
      "valueFrom" = aws_ssm_parameter.idp_load_test_password.arn
    },
    {
      "name"      = "TOTP_SECRET",
      "valueFrom" = aws_ssm_parameter.idp_load_test_totp_secret.arn
    }
  ]
}

#
# ECS load test task definition
#
resource "aws_ecs_task_definition" "idp_load_test" {
  family             = "idp-load-test"
  cpu                = 8192
  memory             = 16384
  execution_role_arn = aws_iam_role.idp_load_test_task.arn
  task_role_arn      = aws_iam_role.idp_load_test_task.arn
  container_definitions = jsonencode([{
    name      = "idp-load-test"
    cpu       = 8192
    memory    = 16384
    essential = true
    command   = ["run", "--quiet", "/test/login.js"]
    image     = "${aws_ecr_repository.idp_load_test.repository_url}:latest"
    linuxParameters = {
      capabilities : {
        add : [],
        drop : ["ALL"]
      }
      initProcessEnabled = true
    }
    ulimits : [
      {
        name : "nofile",
        softLimit : 65536,
        hardLimit : 65536
      },
      {
        name : "nproc",
        softLimit : 65536,
        hardLimit : 65536
      }
    ],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        awslogs-region        = var.region,
        awslogs-group         = aws_cloudwatch_log_group.idp_load_test.name,
        awslogs-stream-prefix = "task"
      }
    }
    environment = local.idp_load_test_container_env
    secrets     = local.idp_load_test_container_secrets
  }])
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  tags = var.common_tags
}

#
# IAM role and policy for ECS task
#
resource "aws_iam_role" "idp_load_test_task" {
  name               = "idp_load_test_ecs_task_role"
  assume_role_policy = data.aws_iam_policy_document.idp_load_test_task_assume.json
  tags               = var.core_tags
}

data "aws_iam_policy_document" "idp_load_test_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "idp_load_test_task" {
  name   = "idp_load_test_ecs_task_policy"
  path   = "/"
  policy = data.aws_iam_policy_document.idp_load_test_task_combined.json
  tags   = var.core_tags
}

data "aws_iam_policy_document" "idp_load_test_task_combined" {
  source_policy_documents = concat([
    data.aws_iam_policy_document.idp_load_test_task_ecr.json,
    data.aws_iam_policy_document.idp_load_test_task_logs.json,
    data.aws_iam_policy_document.idp_load_test_ssm_parameters.json,
  ])
}

data "aws_iam_policy_document" "idp_load_test_task_ecr" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "idp_load_test_task_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.idp_load_test.arn}:*",
    ]
  }
}

data "aws_iam_policy_document" "idp_load_test_ssm_parameters" {
  statement {
    sid    = "GetSSMParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.idp_load_test_client_id.arn,
      aws_ssm_parameter.idp_load_test_username.arn,
      aws_ssm_parameter.idp_load_test_password.arn,
      aws_ssm_parameter.idp_load_test_totp_secret.arn,
    ]
  }
}

resource "aws_iam_role_policy_attachment" "idp_load_test_task" {
  role       = aws_iam_role.idp_load_test_task.name
  policy_arn = aws_iam_policy.idp_load_test_task.arn
}

#
# Log group
#
resource "aws_cloudwatch_log_group" "idp_load_test" {
  name              = "/aws/ecs/idp-load-test"
  retention_in_days = 14
  tags              = var.core_tags
}
