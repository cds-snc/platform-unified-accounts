terraform {
  source = "../..//aws"
}

inputs = {
  enable_waf_geo_restriction = true

  idp_cluster_capacity_provider = "FARGATE"
  idp_database                  = "idp"
  idp_database_instance_count   = 1
  idp_database_min_acu          = 0
  idp_database_max_acu          = 10

  idp_event_exporter_anaomaly_thresholds = {
    "user.human.added"                 = 50
    "user.human.email.verified"        = 50
    "user.human.password.changed"      = 5
    "user.human.mfa.u2f.token.added"   = 50
    "user.human.mfa.u2f.token.removed" = 5
    "user.human.mfa.otp.added"         = 50
    "user.human.mfa.otp.removed"       = 5
    "user.machine.added"               = 5
    "user.machine.key.added"           = 5
    "user.machine.key.removed"         = 5
    "user.pat.added"                   = 5
    "user.pat.removed"                 = 5
  }

  idp_login_task_cpu           = 1024
  idp_login_task_memory        = 2048
  idp_login_task_desired_count = 1
  idp_login_task_min_capacity  = 1
  idp_login_task_max_capacity  = 4
  idp_task_cpu                 = 2048
  idp_task_memory              = 4096
  idp_task_desired_count       = 1
  idp_task_min_capacity        = 1
  idp_task_max_capacity        = 4
}

include {
  path = find_in_parent_folders("root.hcl")
}
