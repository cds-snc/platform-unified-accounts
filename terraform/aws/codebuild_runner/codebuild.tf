resource "aws_codestarconnections_connection" "github" {
  name          = "github-runner-connection"
  provider_type = "GitHub"
  tags          = var.common_tags
}
