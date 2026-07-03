locals {
  ecr_repos = toset([
    "alarms-slack",
    "idp",
    "idp-cleanup-users",
    "idp-event-exporter",
    "idp-login",
  ])
}

resource "aws_ecr_repository" "repo" {
  for_each = local.ecr_repos

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "repo" {
  for_each = local.ecr_repos

  repository = aws_ecr_repository.repo[each.key].name
  policy     = data.aws_ecr_lifecycle_policy_document.repo.json
}

data "aws_ecr_lifecycle_policy_document" "repo" {
  rule {
    priority    = 10
    description = "Keep last 20 git SHA tagged images"

    selection {
      tag_status      = "tagged"
      tag_prefix_list = ["sha-"]
      count_type      = "imageCountMoreThan"
      count_number    = 20
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 20
    description = "Keep last 20 PR SHA tagged images"

    selection {
      tag_status      = "tagged"
      tag_prefix_list = ["pr-"]
      count_type      = "imageCountMoreThan"
      count_number    = 20
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 30
    description = "Expire untagged images older than 1 day"

    selection {
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = 1
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 40
    description = "Archive images not pulled in 90 days"

    selection {
      tag_status   = "any"
      count_type   = "sinceImagePulled"
      count_unit   = "days"
      count_number = 90
    }

    action {
      type                 = "transition"
      target_storage_class = "archive"
    }
  }

  rule {
    priority    = 50
    description = "Expire images archived for more than 90 days"

    selection {
      tag_status    = "any"
      storage_class = "archive"
      count_type    = "sinceImageTransitioned"
      count_unit    = "days"
      count_number  = 90
    }

    action {
      type = "expire"
    }
  }
}

moved {
  from = aws_ecr_repository.alarms_slack
  to   = aws_ecr_repository.repo["alarms-slack"]
}

moved {
  from = aws_ecr_lifecycle_policy.alarms_slack
  to   = aws_ecr_lifecycle_policy.repo["alarms-slack"]
}

moved {
  from = aws_ecr_repository.idp
  to   = aws_ecr_repository.repo["idp"]
}

moved {
  from = aws_ecr_lifecycle_policy.idp
  to   = aws_ecr_lifecycle_policy.repo["idp"]
}

moved {
  from = aws_ecr_repository.idp_event_exporter
  to   = aws_ecr_repository.repo["idp-event-exporter"]
}

moved {
  from = aws_ecr_lifecycle_policy.idp_event_exporter
  to   = aws_ecr_lifecycle_policy.repo["idp-event-exporter"]
}

moved {
  from = aws_ecr_repository.idp_login
  to   = aws_ecr_repository.repo["idp-login"]
}

moved {
  from = aws_ecr_lifecycle_policy.idp_login
  to   = aws_ecr_lifecycle_policy.repo["idp-login"]
}
