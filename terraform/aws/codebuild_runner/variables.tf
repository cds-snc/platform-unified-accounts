variable "billing_tag_value" {
  description = "Billing tag value to apply to all resources"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "github_runner_group_id" {
  description = "GitHub Actions runner group ID for the CodeBuild project"
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs to associate with the CodeBuild project"
  type        = list(string)
}

variable "subnet_ids" {
  description = "Subnet IDs where the CodeBuild project will be deployed"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID where the CodeBuild project will be deployed"
  type        = string
}

