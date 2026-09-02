#
# Client VPN that will allow users in the specified IAM Identity Center group
# access to Zitadel console and API through the internal ALB.
#
module "client_vpn" {
  source = "github.com/cds-snc/terraform-modules//client_vpn?ref=v11.4.6"

  endpoint_name         = "private-subnets"
  access_group_id       = var.client_vpn_access_group_id
  authentication_option = "federated-authentication"
  banner_text           = "Platform Unified Accounts ${upper(var.env)}. This is a private network; only authorized users may connect and should take care not to cause service disruptions."

  vpc_id              = module.idp_vpc.vpc_id
  vpc_cidr_block      = module.idp_vpc.cidr_block
  subnet_cidr_blocks  = module.idp_vpc.private_subnet_cidr_blocks
  subnet_ids          = module.idp_vpc.private_subnet_ids
  acm_certificate_arn = aws_acm_certificate.client_vpn.arn
  add_dns_servers     = false

  # Only create a self-service portal in prod  
  # The client config can still be downloaded from the AWS console
  self_service_portal                            = var.env == "production" ? "enabled" : "disabled"
  client_vpn_self_service_saml_metadata_document = var.env == "production" ? var.client_vpn_self_service_saml_metadata : null
  client_vpn_saml_metadata_document              = var.client_vpn_saml_metadata

  billing_tag_value = var.billing_tag_value
}

#
# Certificate used for VPN communication
#
resource "tls_private_key" "client_vpn" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "client_vpn" {
  private_key_pem       = tls_private_key.client_vpn.private_key_pem
  validity_period_hours = 43800 # 5 years
  early_renewal_hours   = 672   # Generate new cert if Terraform is run within 4 weeks of expiry
  set_authority_key_id  = true
  set_subject_key_id    = true

  subject {
    common_name = "vpn.${var.domain}"
  }

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "ipsec_end_system",
    "ipsec_tunnel",
    "any_extended",
    "cert_signing",
  ]
}

resource "aws_acm_certificate" "client_vpn" {
  private_key      = tls_private_key.client_vpn.private_key_pem
  certificate_body = tls_self_signed_cert.client_vpn.cert_pem

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}