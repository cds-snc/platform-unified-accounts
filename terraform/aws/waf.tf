locals {
  excluded_bot_control_rules = [
    "CategoryHttpLibrary",       # Blocks OIDC auth flow
    "SignalAutomatedBrowser",    # Block integration tests
    "SignalNonBrowserUserAgent", # Blocks API access
  ]
  excluded_common_rules = [
    "EC2MetaDataSSRF_BODY",          # Rule is blocking IdP OIDC app creation
    "EC2MetaDataSSRF_QUERYARGUMENTS" # Rule is blocking IdP OIDC login
  ]
  rate_limit_all        = 1000
  rate_limit_mutating   = 500
  rate_limit_contact_us = 10
}

resource "aws_wafv2_web_acl" "idp" {
  name  = "idp"
  scope = "REGIONAL"

  default_action {
    block {}
  }

  rule {
    name     = "InvalidHost"
    priority = 1

    action {
      block {}
    }

    statement {
      not_statement {
        statement {
          byte_match_statement {
            field_to_match {
              single_header {
                name = "host"
              }
            }
            text_transformation {
              priority = 1
              type     = "COMPRESS_WHITE_SPACE"
            }
            text_transformation {
              priority = 2
              type     = "LOWERCASE"
            }
            positional_constraint = "EXACTLY"
            search_string         = var.domain
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "InvalidHost"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "BlockLargeRequests"
    priority = 10

    action {
      block {}
    }

    statement {
      or_statement {
        statement {
          size_constraint_statement {
            field_to_match {
              body {
                oversize_handling = "MATCH"
              }
            }
            comparison_operator = "GT"
            size                = 8192
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          size_constraint_statement {
            field_to_match {
              cookies {
                match_pattern {
                  all {}
                }
                match_scope       = "ALL"
                oversize_handling = "MATCH"
              }
            }
            comparison_operator = "GT"
            size                = 8192
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          size_constraint_statement {
            field_to_match {
              headers {
                match_pattern {
                  all {}
                }
                match_scope       = "ALL"
                oversize_handling = "MATCH"
              }
            }
            comparison_operator = "GT"
            size                = 8192
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockLargeRequests"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "CanadaOnlyGeoRestriction"
    priority = 30

    action {
      dynamic "block" {
        for_each = var.enable_waf_geo_restriction == true ? [""] : []
        content {}
      }

      dynamic "count" {
        for_each = var.enable_waf_geo_restriction == false ? [""] : []
        content {}
      }
    }

    statement {
      not_statement {
        statement {
          or_statement {
            statement {
              geo_match_statement {
                country_codes = ["CA"]
              }
            }
            statement {
              byte_match_statement {
                field_to_match {
                  single_header {
                    name = "waf-geo-restriction-bypass"
                  }
                }
                text_transformation {
                  priority = 1
                  type     = "NONE"
                }
                positional_constraint = "EXACTLY"
                search_string         = var.waf_geo_restriction_bypass
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CanadaOnlyGeoRestriction"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AllRequestLimitIP"
    priority = 50

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_all
        aggregate_key_type = "IP"

      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllRequestLimit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AllRequestLimitJA4"
    priority = 60

    action {
      challenge {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_all
        aggregate_key_type = "CUSTOM_KEYS"

        custom_key {
          ja4_fingerprint {
            fallback_behavior = "NO_MATCH"
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllRequestLimitJA4"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ContactUsPostBlockOversizedBody"
    priority = 63

    action {
      block {}
    }
    statement {
      and_statement {
        statement {
          byte_match_statement {
            field_to_match {
              method {}
            }
            positional_constraint = "EXACTLY"
            search_string         = "post"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "CONTAINS"
            search_string         = "/contact-us"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          size_constraint_statement {
            field_to_match {
              body {
                oversize_handling = "MATCH"
              }
            }
            comparison_operator = "GT"
            size                = 4096
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ContactUsPostBlockOversizedBody"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ContactUsPostRateLimitIP"
    priority = 65

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_contact_us
        aggregate_key_type = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                field_to_match {
                  method {}
                }
                positional_constraint = "EXACTLY"
                search_string         = "post"
                text_transformation {
                  priority = 1
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                field_to_match {
                  uri_path {}
                }
                positional_constraint = "CONTAINS"
                search_string         = "/contact-us"
                text_transformation {
                  priority = 1
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ContactUsPostRateLimitIP"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ContactUsPostChallenge"
    priority = 67

    action {
      challenge {}
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            field_to_match {
              method {}
            }
            positional_constraint = "EXACTLY"
            search_string         = "post"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "CONTAINS"
            search_string         = "/contact-us"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ContactUsPostChallenge"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ContactUsPostRateLimitJA4"
    priority = 69

    action {
      challenge {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_contact_us
        aggregate_key_type = "CUSTOM_KEYS"

        custom_key {
          ja4_fingerprint {
            fallback_behavior = "NO_MATCH"
          }
        }

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                field_to_match {
                  method {}
                }
                positional_constraint = "EXACTLY"
                search_string         = "post"
                text_transformation {
                  priority = 1
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                field_to_match {
                  uri_path {}
                }
                positional_constraint = "CONTAINS"
                search_string         = "/contact-us"
                text_transformation {
                  priority = 1
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ContactUsPostRateLimitJA4"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "MutatingRequestLimitIP"
    priority = 70

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_mutating
        aggregate_key_type = "IP"
        scope_down_statement {
          regex_match_statement {
            field_to_match {
              method {}
            }
            regex_string = "^(delete|patch|post|put)$"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "MutatingRequestLimitIP"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "MutatingRequestLimitJA4"
    priority = 80

    action {
      challenge {}
    }

    statement {
      rate_based_statement {
        limit              = local.rate_limit_mutating
        aggregate_key_type = "CUSTOM_KEYS"

        custom_key {
          ja4_fingerprint {
            fallback_behavior = "NO_MATCH"
          }
        }

        scope_down_statement {
          regex_match_statement {
            field_to_match {
              method {}
            }
            regex_string = "^(delete|patch|post|put)$"
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "MutatingRequestLimitJA4"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAntiDDoSRuleSet"
    priority = 90

    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAntiDDoSRuleSet"
        vendor_name = "AWS"

        managed_rule_group_configs {
          aws_managed_rules_anti_ddos_rule_set {
            client_side_action_config {
              challenge {
                sensitivity     = "HIGH"
                usage_of_action = "ENABLED"
                exempt_uri_regular_expression {
                  regex_string = "/api/|.(acc|avi|css|gif|jpe?g|js|pdf|png|tiff?|ttf|webm|webp|woff2?)$"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAntiDDoSRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 100

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesLinuxRuleSet"
    priority = 110

    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesLinuxRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 120

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        dynamic "rule_action_override" {
          for_each = local.excluded_common_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesBotControlRuleSet"
    priority = 130

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesBotControlRuleSet"
        vendor_name = "AWS"
        managed_rule_group_configs {
          aws_managed_rules_bot_control_rule_set {
            enable_machine_learning = false
            inspection_level        = "COMMON"
          }
        }

        dynamic "rule_action_override" {
          for_each = local.excluded_bot_control_rules
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesBotControlRuleSet"
      sampled_requests_enabled   = true
    }
  }
  #
  # Allow actions must be last in the rule list as they are terminating rules and
  # will prevent any subsequent rules from being evaluated.
  #
  rule {
    name     = "AllowedPath"
    priority = 140

    action {
      allow {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 1
          type     = "LOWERCASE"
        }
        positional_constraint = "STARTS_WITH"
        search_string         = "/ui/v2"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllowedPath"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "idp"
    sampled_requests_enabled   = true
  }

  tags = local.core_tags
}

resource "aws_wafv2_web_acl_association" "idp" {
  resource_arn = aws_lb.idp.arn
  web_acl_arn  = aws_wafv2_web_acl.idp.arn
}

#
# WAF logging
#
resource "aws_wafv2_web_acl_logging_configuration" "idp_waf_logs" {
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.idp_waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.idp.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

resource "aws_kinesis_firehose_delivery_stream" "idp_waf_logs" {
  name        = "aws-waf-logs-idp"
  destination = "extended_s3"

  server_side_encryption {
    enabled = true
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.idp_waf_logs.arn
    prefix             = "waf_acl_logs/AWSLogs/${var.account_id}/"
    bucket_arn         = local.cbs_satellite_bucket_arn
    compression_format = "GZIP"
  }
}

#
# WAF logging IAM role
#
resource "aws_iam_role" "idp_waf_logs" {
  name               = "idp-waf-logs"
  assume_role_policy = data.aws_iam_policy_document.idp_waf_logs_assume.json
  tags               = local.core_tags
}

resource "aws_iam_role_policy" "idp_waf_logs" {
  name   = "idp-waf-logs"
  role   = aws_iam_role.idp_waf_logs.id
  policy = data.aws_iam_policy_document.idp_waf_logs.json
}

data "aws_iam_policy_document" "idp_waf_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "idp_waf_logs" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    resources = [
      local.cbs_satellite_bucket_arn,
      "${local.cbs_satellite_bucket_arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole"
    ]
    resources = [
      "arn:aws:iam::*:role/aws-service-role/wafv2.amazonaws.com/AWSServiceRoleForWAFV2Logging"
    ]
  }
}
