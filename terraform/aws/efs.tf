resource "aws_efs_file_system" "idp" {
  count = var.enable_efs ? 1 : 0

  encrypted = true
  tags      = local.common_tags
}

resource "aws_efs_file_system_policy" "idp" {
  count = var.enable_efs ? 1 : 0

  file_system_id = aws_efs_file_system.idp[0].id
  policy         = data.aws_iam_policy_document.efs_access_point_secure[0].json
}

data "aws_iam_policy_document" "efs_access_point_secure" {
  count = var.enable_efs ? 1 : 0

  statement {
    sid    = "AllowAccessThroughAccessPoint"
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [aws_efs_file_system.idp[0].arn]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values = [
        aws_efs_access_point.idp[0].arn
      ]
    }
  }

  statement {
    sid       = "DenyNonSecureTransport"
    effect    = "Deny"
    actions   = ["*"]
    resources = [aws_efs_file_system.idp[0].arn]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values = [
        "false"
      ]
    }
  }
}

resource "aws_efs_backup_policy" "idp" {
  count = var.enable_efs ? 1 : 0

  file_system_id = aws_efs_file_system.idp[0].id
  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "idp" {
  count = var.enable_efs ? local.vpc_az_count : 0

  file_system_id = aws_efs_file_system.idp[0].id
  subnet_id      = element(module.idp_vpc.private_subnet_ids, count.index)
  security_groups = [
    aws_security_group.idp_efs[0].id
  ]
}

resource "aws_efs_access_point" "idp" {
  count = var.enable_efs ? 1 : 0

  file_system_id = aws_efs_file_system.idp[0].id
  posix_user {
    gid = 1000
    uid = 1000
  }
  root_directory {
    path = "/idp"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = 750
    }
  }
  tags = local.common_tags
}