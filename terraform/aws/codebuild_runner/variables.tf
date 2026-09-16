variable "billing_tag_value" {
  description = "Billing tag value to apply to all resources"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "env" {
  description = "Environment name"
  type        = string
}

variable "github_runner_group_id" {
  description = "GitHub Actions runner group ID for the CodeBuild project"
  type        = string
}

variable "idp_alb_security_group_id" {
  description = "Security group ID of the IdP's internal ALB"
  type        = string
}

variable "idp_vpc_id" {
  description = "VPC ID of the IdP that the CodeBuild project will connect to"
  type        = string
}

variable "idp_vpc_cidr_block" {
  description = "CIDR block of the IdP VPC"
  type        = string
}

variable "idp_vpc_private_route_table_ids" {
  description = "Private route table IDs of the IdP VPC"
  type        = list(string)
}

variable "idp_vpc_public_route_table_ids" {
  description = "Public route table IDs of the IdP VPC"
  type        = list(string)
}
