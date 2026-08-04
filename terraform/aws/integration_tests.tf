locals {
  integration_tests = "platform-unified-accounts-integration-tests"
}

#
# Create the OIDC roles used by the GitHub workflows
# 
module "github_workflow_roles" {
  source = "github.com/cds-snc/terraform-modules//gh_oidc_role?ref=v11.4.5"

  roles = [
    {
      name = local.integration_tests
      claims = [
        {
          repo_name = "platform-unified-accounts-user-portal"
          claim     = "ref:refs/heads/main"
        },
        {
          repo_name = "platform-unified-accounts-user-portal"
          claim     = "pull_request"
        }
      ]
    }
  ]

  billing_tag_value = var.billing_tag_value
}

#
# Upload of integration test results
#
resource "aws_iam_role_policy_attachment" "integration_tests" {
  role       = local.integration_tests
  policy_arn = aws_iam_policy.integration_tests.arn
  depends_on = [module.github_workflow_roles]
}

resource "aws_iam_policy" "integration_tests" {
  name   = local.integration_tests
  path   = "/"
  policy = data.aws_iam_policy_document.integration_tests.json
  tags   = local.core_tags
}

data "aws_iam_policy_document" "integration_tests" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:PutObject"
    ]
    resources = [
      module.integration_tests.s3_bucket_arn,
      "${module.integration_tests.s3_bucket_arn}/*"
    ]
  }
}

#
# S3 bucket to store integration test results
#
module "integration_tests" {
  source            = "github.com/cds-snc/terraform-modules//S3?ref=v11.4.5"
  bucket_name       = "platform-unified-accounts-integration-tests-${var.env}"
  billing_tag_value = var.billing_tag_value

  lifecycle_rule = [
    {
      id      = "expire_all"
      enabled = true
      expiration = {
        days = "14"
      }
    },
    {
      id                                     = "remove_noncurrent_versions"
      enabled                                = true
      abort_incomplete_multipart_upload_days = "7"
      noncurrent_version_expiration = {
        days = "14"
      }
    }
  ]

  versioning = {
    enabled = true
  }
}
