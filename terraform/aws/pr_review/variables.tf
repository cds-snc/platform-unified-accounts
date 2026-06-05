variable "account_id" {
  description = "AWS account ID where PR review resources will be created"
  type        = string
}

variable "billing_tag_value" {
  description = "Value for the billing tag to apply to all resources"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "core_tags" {
  description = "Core tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "ecr_policy" {
  description = "The ECR lifecycle policy JSON content"
  type        = string
}

variable "pr_review_env_ssm_params_get" {
  description = "ARNs of the SSM parameters the PR review environment is able to read"
  type        = list(string)
}

variable "region" {
  description = "AWS region"
  type        = string
}