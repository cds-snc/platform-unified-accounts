resource "aws_ecr_repository" "idp_load_test" {
  name                 = "idp-load-test"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = var.common_tags
}

resource "aws_ecr_lifecycle_policy" "idp_load_test" {
  repository = aws_ecr_repository.idp_load_test.name
  policy     = var.ecr_policy
}
