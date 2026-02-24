variable "account_id" {
  description = "The account ID to perform actions on."
  type        = string
}

variable "billing_tag_value" {
  description = "The billing code to tag our resources with"
  type        = string
}

variable "cbs_satellite_bucket_name" {
  description = "The Cloud Based Sensor bucket name"
  type        = string
}

variable "cloudwatch_slack_webhook_url" {
  description = "The Slack webhook URL for CloudWatch alerts."
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "The domain to use for the service."
  type        = string
}

variable "env" {
  description = "The current running environment"
  type        = string
}

variable "product_name" {
  description = "The name of the product you are deploying."
  type        = string
}

variable "region" {
  description = "The current AWS region"
  type        = string
}

variable "idp_admin_username" {
  description = "IdP administrator username."
  type        = string
  sensitive   = true
}

variable "idp_admin_password" {
  description = "IdP administrator password."
  type        = string
  sensitive   = true
}

variable "idp_cluster_capacity_provider" {
  description = "The capacity provider for the IdP ECS cluster."
  type        = string
}

variable "idp_database" {
  description = "The name of the IdP database."
  type        = string
  sensitive   = true
}

variable "idp_database_min_acu" {
  description = "The minimum serverless capacity for the database."
  type        = number
}

variable "idp_database_max_acu" {
  description = "The maximum serverless capacity for the database."
  type        = number
}

variable "idp_database_username" {
  description = "The IdP username to use for the database."
  type        = string
  sensitive   = true
}

variable "idp_database_password" {
  description = "The IdP password to use for the database."
  type        = string
  sensitive   = true
}

variable "idp_database_admin_username" {
  description = "The cluster's username to use for the database."
  type        = string
  sensitive   = true
}

variable "idp_database_admin_password" {
  description = "The cluster's admin password to use for the database."
  type        = string
  sensitive   = true
}

variable "idp_database_instance_count" {
  description = "The number of instances for the database cluster."
  type        = number
}

variable "idp_loginclient_machine_username" {
  description = "The machine username for the IdP login client."
  type        = string
  sensitive   = true
}

variable "idp_loginclient_pat" {
  description = "The personal access token for the IdP login client."
  type        = string
  sensitive   = true
}

variable "idp_login_task_cpu" {
  description = "The CPU units for the idp login ECS task."
  type        = number
}

variable "idp_login_task_desired_count" {
  description = "The desired number of IdP ECS login tasks."
  type        = number
}

variable "idp_login_task_max_capacity" {
  description = "The maximum autoscaling capacity for IdP ECS login tasks."
  type        = number
}

variable "idp_login_task_memory" {
  description = "The memory units for the IdP ECS login task."
  type        = number
}

variable "idp_login_task_min_capacity" {
  description = "The minimum autoscaling capacity for IdP ECS login tasks."
  type        = number
}

variable "idp_secret_key" {
  description = "The secret key to use for the idp instance."
  type        = string
  sensitive   = true
}

variable "idp_task_cpu" {
  description = "The CPU units for the idp ECS task."
  type        = number
}

variable "idp_task_desired_count" {
  description = "The desired number of IdP ECS tasks."
  type        = number
}

variable "idp_task_max_capacity" {
  description = "The maximum autoscaling capacity for IdP ECS tasks."
  type        = number
}

variable "idp_task_memory" {
  description = "The memory units for the IdP ECS task."
  type        = number
}

variable "idp_task_min_capacity" {
  description = "The minimum autoscaling capacity for IdP ECS tasks."
  type        = number
}

variable "security_txt_content" {
  description = "The content of the /.well-known/security.txt response."
  type        = string
}