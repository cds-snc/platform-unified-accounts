terraform {
  source = "../..//aws"
}

inputs = {
  enable_waf_geo_restriction = true

  idp_cluster_capacity_provider = "FARGATE_SPOT"
  idp_database                  = "idp"
  idp_database_instance_count   = 1
  idp_database_min_acu          = 0
  idp_database_max_acu          = 10
  idp_login_task_cpu            = 1024
  idp_login_task_memory         = 2048
  idp_login_task_desired_count  = 1
  idp_login_task_min_capacity   = 1
  idp_login_task_max_capacity   = 4
  idp_task_cpu                  = 2048
  idp_task_memory               = 4096
  idp_task_desired_count        = 1
  idp_task_min_capacity         = 1
  idp_task_max_capacity         = 4
}

include {
  path = find_in_parent_folders("root.hcl")
}
