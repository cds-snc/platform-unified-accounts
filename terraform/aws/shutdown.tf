module "schedule_shutdown" {
  count = var.env == "staging" ? 1 : 0

  source = "github.com/cds-snc/terraform-modules//schedule_shutdown?ref=v10.11.0"

  ecs_service_arns = [
    module.idp_ecs.service_id,
    module.login_ecs.service_id,
  ]

  cloudwatch_alarm_arns = concat(
    [for alarm in aws_cloudwatch_metric_alarm.idp_load_balancer_unhealthy_hosts : alarm.arn],
    [for alarm in aws_cloudwatch_metric_alarm.idp_load_balancer_healthy_hosts : alarm.arn]
  )

  schedule_shutdown = "cron(0 23 * * ? *)"       # 11pm UTC, every day
  schedule_startup  = "cron(0 11 ? * MON-FRI *)" # 11am UTC, Monday-Friday

  billing_tag_value = var.billing_tag_value
}
