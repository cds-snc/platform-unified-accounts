#
# IdP primary certificate
#
resource "aws_acm_certificate" "idp" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "idp_validation" {
  zone_id = aws_route53_zone.idp.zone_id

  for_each = {
    for dvo in aws_acm_certificate.idp.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  type            = each.value.type
  ttl             = 60
}

resource "aws_acm_certificate_validation" "idp" {
  certificate_arn         = aws_acm_certificate.idp.arn
  validation_record_fqdns = [for record in aws_route53_record.idp_validation : record.fqdn]
}

#
# ECS Service Connect: encryption-in-transit between ECS services
#
resource "aws_acmpca_certificate_authority" "ecs_service_connect" {
  type                            = "ROOT"
  usage_mode                      = "SHORT_LIVED_CERTIFICATE"
  permanent_deletion_time_in_days = 7

  certificate_authority_configuration {
    key_algorithm     = "EC_secp384r1"
    signing_algorithm = "SHA384WITHECDSA"

    subject {
      common_name         = "ecs.idp"
      organization        = "CDS"
      organizational_unit = "Platform"
    }
  }

  # Revocation not supported for short-lived certificates
  revocation_configuration {
    crl_configuration {
      enabled = false
    }
  }

  tags = local.common_tags
}

resource "aws_acmpca_certificate" "ecs_service_connect" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.ecs_service_connect.arn
  certificate_signing_request = aws_acmpca_certificate_authority.ecs_service_connect.certificate_signing_request
  signing_algorithm           = "SHA384WITHECDSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "DAYS"
    value = 7
  }
}

resource "aws_acmpca_certificate_authority_certificate" "ecs_service_connect" {
  certificate_authority_arn = aws_acmpca_certificate_authority.ecs_service_connect.arn
  certificate               = aws_acmpca_certificate.ecs_service_connect.certificate
  certificate_chain         = aws_acmpca_certificate.ecs_service_connect.certificate_chain
}
