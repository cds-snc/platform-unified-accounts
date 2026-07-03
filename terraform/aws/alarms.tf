locals {
  # Database audit events
  database_audit_event_filters = [
    ",DDL,",
    ",ROLE,",
    ",WRITE,TRUNCATE,",
    ",WRITE,INSERT,* projections.org_members",
    ",WRITE,UPDATE,* projections.org_members",
    ",WRITE,INSERT,* projections.instance_members",
    ",WRITE,UPDATE,* projections.instance_members",
  ]
  database_audit_event_skip_filters = [
    "create unlogged table if not exists",
  ]
  database_audit_event_filter_pattern = "[(w=\"*${join("*\" || w=\"*", local.database_audit_event_filters)}*\") && w!=\"*${join("*\" && w!=\"*", local.database_audit_event_skip_filters)}*\"]"
  database_audit_event_log_group_name = "/aws/rds/cluster/${module.idp_database.rds_cluster_id}/postgresql"

  # IdP errors
  idp_error_filters = [
    "level=error",
    "level=ERROR",
  ]
  idp_error_skip_filters = [
    "already been committed",
    "AuthRequest.NotExisting",
  ]
  idp_error_metric_pattern = "[(w=\"*${join("*\" || w=\"*", local.idp_error_filters)}*\") && w!=\"*${join("*\" && w!=\"*", local.idp_error_skip_filters)}*\"]"

  # IdP Login errors
  idp_login_error_filters = [
    "error"
  ]
  idp_login_skip_filters = [
    "already_exists",
    "COMMAND-Sx208nt", # [failed_precondition] Auth Request has already been handled
    "failed_precondition",
    "invalid_argument",
    "not_found",
    "permission_denied",
    "SyntaxError",
    "TypeError",
    "Untrusted",
    "zitadel.v1.ErrorDetail",
  ]
  idp_login_error_metric_pattern = "[(w=\"*${join("*\" || w=\"*", local.idp_login_error_filters)}*\") && w!=\"*${join("*\" && w!=\"*", local.idp_login_skip_filters)}*\"]"

  # IdP Cleanup Users errors
  idp_cleanup_users_error_filters = [
    "error",
    "exception"
  ]
  idp_cleanup_users_error_metric_pattern = "[(w=\"*${join("*\" || w=\"*", local.idp_cleanup_users_error_filters)}*\")]"


  # IdP Event Exporter errors
  idp_event_exporter_error_filters = [
    "error",
    "exception"
  ]
  idp_event_exporter_error_metric_pattern = "[(w=\"*${join("*\" || w=\"*", local.idp_event_exporter_error_filters)}*\")]"

  # ECS and ALB thresholds
  threshold_ecs_high_cpu      = 80   # percentage
  threshold_ecs_high_memory   = 80   # percentage
  threshold_idp_response_time = 1000 # milliseconds
  threshold_lb_response_time  = 1    # seconds

  ecs_services = [
    module.login_ecs,
    module.idp_ecs
  ]
  lb_target_groups = merge(
    { for key, value in aws_lb_target_group.idp : "idp-${lower(key)}" => value },
    { idp_login = aws_lb_target_group.idp_login }
  )
  error_logged_filter_patterns = {
    idp = {
      error_filters  = local.idp_error_filters
      pattern        = local.idp_error_metric_pattern
      log_group_name = module.idp_ecs.cloudwatch_log_group_name
    }
    idp_login = {
      error_filters  = local.idp_login_error_filters
      pattern        = local.idp_login_error_metric_pattern
      log_group_name = module.login_ecs.cloudwatch_log_group_name
    }
    idp_cleanup_users = {
      error_filters  = local.idp_cleanup_users_error_filters
      pattern        = local.idp_cleanup_users_error_metric_pattern
      log_group_name = module.idp_cleanup_users_lambda.lambda_function_cloudwatch_log_group_name
    }
    idp_event_exporter = {
      error_filters  = local.idp_event_exporter_error_filters
      pattern        = local.idp_event_exporter_error_metric_pattern
      log_group_name = module.event_exporter_lambda.lambda_function_cloudwatch_log_group_name
    }
  }

  lambda_functions = {
    alarms_slack = {
      name = module.alarms_slack.function_name
    }
    idp_cleanup_users = {
      name = module.idp_cleanup_users_lambda.lambda_function_name
    }
    idp_event_exporter = {
      name = module.event_exporter_lambda.lambda_function_name
    }
  }
}

#
# ECS resource use
#
resource "aws_cloudwatch_metric_alarm" "idp_ecs_high_cpu" {
  for_each = { for service in local.ecs_services : service.service_name => service }

  alarm_name          = "${each.key}-high-cpu"
  alarm_description   = "`${each.key}` high CPU use over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Maximum"
  threshold           = local.threshold_ecs_high_cpu
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    ClusterName = module.idp_ecs.cluster_name
    ServiceName = each.key
  }

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "idp_ecs_high_memory" {
  for_each = { for service in local.ecs_services : service.service_name => service }

  alarm_name          = "${each.key}-high-memory"
  alarm_description   = "`${each.key}` high memory use over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Maximum"
  threshold           = local.threshold_ecs_high_memory
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    ClusterName = module.idp_ecs.cluster_name
    ServiceName = each.key
  }

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "idp_login_slow_idp_responses" {
  alarm_name          = "idp-login-slow-idp-responses"
  alarm_description   = "User portal responses from the IdP consistently over 1 second over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  datapoints_to_alarm = "4"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = local.threshold_idp_response_time
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    ClusterName         = module.idp_ecs.cluster_name
    ServiceName         = "idp-login"
    TargetDiscoveryName = "idp"
  }

  tags = local.core_tags
}

#
# Load balancer
#
resource "aws_cloudwatch_metric_alarm" "idp_load_balancer_unhealthy_hosts" {
  for_each = local.lb_target_groups

  alarm_name          = "${each.key}-load-balancer-unhealthy-hosts"
  alarm_description   = "There are unhealthy ${each.key} target group hosts in a 1 minute period."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = "1"
  evaluation_periods  = "1"
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    LoadBalancer = aws_lb.idp.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "idp_load_balancer_healthy_hosts" {
  for_each = local.lb_target_groups

  alarm_name          = "${each.key}-load-balancer-healthy-hosts"
  alarm_description   = "There are no healthy hosts for the ${each.key} target group in a 1 minute period."
  comparison_operator = "LessThanThreshold"
  threshold           = "1"
  evaluation_periods  = "1"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    LoadBalancer = aws_lb.idp.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "idp_load_balancer_response_time" {
  for_each = local.lb_target_groups

  alarm_name          = "${each.key}-load-balancer-response-time"
  alarm_description   = "Response time for the ${each.key} target group is consistently over 1 second over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  datapoints_to_alarm = "4"
  threshold           = local.threshold_lb_response_time
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  metric_query {
    id          = "response_time"
    return_data = "true"
    metric {
      metric_name = "TargetResponseTime"
      namespace   = "AWS/ApplicationELB"
      period      = "60"
      stat        = "Average"
      dimensions = {
        LoadBalancer = aws_lb.idp.arn_suffix
        TargetGroup  = each.value.arn_suffix
      }
    }
  }

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "idp_database_cpu_writer" {
  alarm_name          = "idp-database-cpu-writer"
  alarm_description   = "CPU for database cluster writer over 80% over 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  threshold           = 80
  period              = "300"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  dimensions = {
    DBClusterIdentifier = module.idp_database.rds_cluster_id
    Role                = "WRITER"
  }

  tags = local.core_tags
}

#
# Errors logged
#
resource "aws_cloudwatch_log_subscription_filter" "error_logged" {
  for_each = local.error_logged_filter_patterns

  name            = "${each.key}-error-logged"
  log_group_name  = each.value.log_group_name
  filter_pattern  = each.value.pattern
  destination_arn = module.alarms_slack.function_arn
}

#
# Audit events
#
resource "aws_cloudwatch_log_subscription_filter" "audit_event_logged" {
  name            = "audit-event-logged"
  log_group_name  = module.event_exporter_lambda.lambda_function_cloudwatch_log_group_name
  filter_pattern  = "AEVT"
  destination_arn = module.alarms_slack.function_arn
}

resource "aws_cloudwatch_log_subscription_filter" "database_pgaudit" {
  name            = "database-pgaudit"
  log_group_name  = local.database_audit_event_log_group_name
  filter_pattern  = local.database_audit_event_filter_pattern
  destination_arn = module.alarms_slack.function_arn
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambda_functions

  alarm_name          = "${each.key}-lambda-errors"
  alarm_description   = "`${each.value.name}` Lambda failed invocation over 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.name
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  tags = local.core_tags
}

#
# SES bounces and complaints
#
resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate_high" {
  alarm_name          = "ses-bounce-rate-high"
  alarm_description   = "SES Warning - bounce rate >=7% over the last 12 hours"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.BounceRate"
  namespace           = "AWS/SES"
  period              = 60 * 60 * 12
  statistic           = "Average"
  threshold           = 7 / 100
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  tags = local.core_tags
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate_high" {
  alarm_name          = "ses-complaint-rate-high"
  alarm_description   = "SES Warning - complaint rate >=0.4% over the last 12 hours"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Reputation.ComplaintRate"
  namespace           = "AWS/SES"
  period              = 60 * 60 * 12
  statistic           = "Average"
  threshold           = 0.4 / 100
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alert_warning.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alert_ok.arn]

  tags = local.core_tags
}

#
# Log Insight queries
#
resource "aws_cloudwatch_query_definition" "ecs_errors" {
  for_each = local.error_logged_filter_patterns

  name            = "${each.key} errors"
  log_group_names = [each.value.log_group_name]
  query_string    = <<-QUERY
    fields @timestamp, @message, @logStream
    | filter @message like /${join("|", each.value.error_filters)}/
    | sort @timestamp desc
    | limit 100
  QUERY
}

#
# Alarm error logs to Slack
#
module "alarms_slack" {
  source    = "github.com/cds-snc/terraform-modules//lambda?ref=v11.3.5"
  name      = "alarms-slack"
  ecr_arn   = aws_ecr_repository.repo["alarms-slack"].arn
  image_uri = "${aws_ecr_repository.repo["alarms-slack"].repository_url}:latest"

  architectures = ["arm64"]
  memory        = 1024
  timeout       = 10
  policies      = [data.aws_iam_policy_document.alarms_slack.json]

  environment_variables = {
    SLACK_WEBHOOK_SSM_PARAMETER_NAME = aws_ssm_parameter.cloudwatch_slack_webhook_url.name
  }

  billing_tag_value = var.billing_tag_value
}

data "aws_iam_policy_document" "alarms_slack" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.cloudwatch_slack_webhook_url.arn
    ]
  }
}

resource "aws_lambda_permission" "alarms_slack" {
  for_each = local.error_logged_filter_patterns

  statement_id  = "AllowExecutionFromCloudWatch-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = module.alarms_slack.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:${var.region}:${var.account_id}:log-group:${each.value.log_group_name}:*"
}

resource "aws_lambda_permission" "alarms_slack_database_pgaudit" {
  statement_id  = "AllowExecutionFromCloudWatch-database-pgaudit"
  action        = "lambda:InvokeFunction"
  function_name = module.alarms_slack.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:${var.region}:${var.account_id}:log-group:${local.database_audit_event_log_group_name}:*"
}

resource "aws_ssm_parameter" "cloudwatch_slack_webhook_url" {
  name  = "cloudwatch_slack_webhook_url"
  type  = "SecureString"
  value = var.cloudwatch_slack_webhook_url
  tags  = local.core_tags
}
