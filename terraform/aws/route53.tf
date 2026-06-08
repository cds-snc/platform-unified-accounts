resource "aws_route53_zone" "idp" {
  name = var.domain
  tags = local.common_tags
}

resource "aws_route53_record" "idp_A" {
  zone_id = aws_route53_zone.idp.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_lb.idp.dns_name
    zone_id                = aws_lb.idp.zone_id
    evaluate_target_health = true
  }
}

# SES verification
resource "aws_route53_record" "idp_verification_TXT" {
  zone_id = aws_route53_zone.idp.zone_id
  name    = "_amazonses.${aws_ses_domain_identity.idp.id}"
  type    = "TXT"
  ttl     = "600"
  records = [aws_ses_domain_identity.idp.verification_token]
}

# Email sending
resource "aws_route53_record" "idp_spf_TXT" {
  zone_id = aws_route53_zone.idp.zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = "300"
  records = [
    "v=spf1 include:amazonses.com -all"
  ]
}

resource "aws_route53_record" "idp_dkim_CNAME" {
  count   = 3
  zone_id = aws_route53_zone.idp.zone_id
  name    = "${element(aws_ses_domain_dkim.idp.dkim_tokens, count.index)}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = "300"
  records = [
    "${element(aws_ses_domain_dkim.idp.dkim_tokens, count.index)}.dkim.amazonses.com",
  ]
}

resource "aws_route53_record" "idp_dmarc_TXT" {
  zone_id = aws_route53_zone.idp.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = "300"
  records = [
    "v=DMARC1; p=reject; sp=reject; pct=100; rua=mailto:CDS.SECURITY-SECURITE.SNC@servicecanada.gc.ca"
  ]
}

module "resolver_dns" {
  source           = "github.com/cds-snc/terraform-modules//resolver_dns?ref=v11.3.5"
  vpc_id           = module.idp_vpc.vpc_id
  firewall_enabled = true

  allowed_domains = [
    "${var.domain}.",
    "*.amazonaws.com.",
    "api.notification.canada.ca.",
    "idp.ecs.local."
  ]

  billing_tag_value = var.billing_tag_value
}
