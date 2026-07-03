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
  policy = jsonencode({
    "rules" : [
      {
        "rulePriority" : 10,
        "description" : "Keep last 20 git SHA tagged images",
        "selection" : {
          "tagStatus" : "tagged",
          "tagPrefixList" : [
            "sha-"
          ],
          "countType" : "imageCountMoreThan",
          "countNumber" : 20
        },
        "action" : {
          "type" : "expire"
        }
      },
      {
        "rulePriority" : 20,
        "description" : "Keep last 20 PR SHA tagged images",
        "selection" : {
          "tagStatus" : "tagged",
          "tagPrefixList" : [
            "pr-"
          ],
          "countType" : "imageCountMoreThan",
          "countNumber" : 20
        },
        "action" : {
          "type" : "expire"
        }
      },
      {
        "rulePriority" : 30,
        "description" : "Expire untagged images older than 1 day",
        "selection" : {
          "tagStatus" : "untagged",
          "countType" : "sinceImagePushed",
          "countUnit" : "days",
          "countNumber" : 1
        },
        "action" : {
          "type" : "expire"
        }
      },
      {
        "rulePriority" : 40,
        "description" : "Archive images not pulled in 90 days",
        "selection" : {
          "tagStatus" : "any",
          "countType" : "sinceImagePulled",
          "countUnit" : "days",
          "countNumber" : 90
        },
        "action" : {
          "type" : "transition",
          "targetStorageClass" : "archive"
        }
      },
      {
        "rulePriority" : 50,
        "description" : "Expire images archived for more than 90 days",
        "selection" : {
          "tagStatus" : "any",
          "storageClass" : "archive",
          "countType" : "sinceImageTransitioned",
          "countUnit" : "days",
          "countNumber" : 90
        },
        "action" : {
          "type" : "expire"
        }
      }
    ]
  })
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
