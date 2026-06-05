#
# AWS Shield Advanced
#
resource "aws_shield_subscription" "idp" {
  auto_renew = "ENABLED"
}

resource "aws_shield_protection" "idp_alb" {
  name         = "idp-alb"
  resource_arn = aws_lb.idp.arn
  tags         = local.core_tags
}

resource "aws_shield_protection" "idp_route53" {
  name         = "idp-route53"
  resource_arn = aws_route53_zone.idp.arn
  tags         = local.core_tags
}

resource "aws_shield_application_layer_automatic_response" "idp_alb" {
  resource_arn = aws_lb.idp.arn
  action       = "BLOCK"
}
