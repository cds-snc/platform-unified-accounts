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

variable "enable_waf_geo_restriction" {
  description = "Whether to enable WAF geo restriction rule."
  type        = bool
  default     = false
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

variable "idp_cleanup_users_key_json" {
  description = "The JSON key for the IdP cleanup users lambda to authenticate with the IdP API."
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

variable "idp_event_exporter_key_json" {
  description = "The JSON key for the IdP event exporter to authenticate with the IdP API."
  type        = string
  sensitive   = true
}

variable "idp_load_test_client_id" {
  description = "The Zitadel client ID for the IdP load test."
  type        = string
  sensitive   = true
  default     = ""
}

variable "idp_load_test_password" {
  description = "The password for the IdP load test user."
  type        = string
  sensitive   = true
  default     = ""
}

variable "idp_load_test_totp_secret" {
  description = "The TOTP secret for the IdP load test user."
  type        = string
  sensitive   = true
  default     = ""
}

variable "idp_load_test_username" {
  description = "The username for the IdP load test user."
  type        = string
  sensitive   = true
  default     = ""
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

variable "idp_zitadel_org" {
  description = "The IdP organization ID."
  type        = string
  sensitive   = true
}

variable "idp_notify_api_key" {
  description = "The API key for the notification service used by the IdP login app."
  type        = string
  sensitive   = true
}

variable "idp_notify_template_id" {
  description = "The template ID for the notification service used by the IdP login app."
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

variable "waf_geo_restriction_bypass" {
  description = "WAF header value that allows bypassing the geo restriction rule. Used for GitHub workflows that run in the US of A."
  type        = string
  sensitive   = true
}

variable "vpn_client_cidr_block" {
  description = "The client CIDR block for the AWS Client VPN endpoint. Must be at least /22 and must not overlap with the VPC CIDR."
  type        = string
}

variable "vpn_saml_provider_arn" {
  description = "The ARN of the IAM SAML identity provider used for Client VPN federated authentication."
  type        = string
}

variable "vpn_server_cert_arn" {
  description = "The ARN of the ACM certificate used as the Client VPN server certificate."
  type        = string
}