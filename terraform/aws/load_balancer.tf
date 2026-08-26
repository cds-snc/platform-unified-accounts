resource "aws_lb" "idp" {
  name               = "idp-${var.env}"
  internal           = false
  load_balancer_type = "application"

  drop_invalid_header_fields = true
  enable_deletion_protection = true
  idle_timeout               = 60

  access_logs {
    bucket  = var.cbs_satellite_bucket_name
    prefix  = "lb_logs"
    enabled = true
  }

  security_groups = [
    aws_security_group.idp_lb.id
  ]
  subnets = module.idp_vpc.public_subnet_ids

  tags = local.core_tags
}

resource "random_string" "alb_idp_tg_suffix" {
  length  = 3
  special = false
  upper   = false
  keepers = {
    port     = 8080
    protocol = "HTTPS"
    path     = "/debug/healthz"
  }
}

resource "random_string" "alb_idp_login_tg_suffix" {
  length  = 3
  special = false
  upper   = false
  keepers = {
    port     = 3000
    protocol = "HTTPS"
    path     = "/ui/v2/healthy"
  }
}

resource "aws_lb_target_group" "idp" {
  for_each = local.protocol_versions

  name                 = "idp-tg-${each.value}-${random_string.alb_idp_tg_suffix.result}"
  port                 = 8080
  protocol             = "HTTPS"
  protocol_version     = each.value
  target_type          = "ip"
  deregistration_delay = 30
  vpc_id               = module.idp_vpc.vpc_id

  health_check {
    enabled  = true
    protocol = "HTTPS"
    path     = "/debug/healthz"
    matcher  = "200"
  }

  stickiness {
    type = "lb_cookie"
  }

  tags = local.core_tags

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      stickiness[0].cookie_name
    ]
  }
}

resource "aws_lb_target_group" "idp_login" {
  name                 = "idp-login-tg-${random_string.alb_idp_login_tg_suffix.result}"
  port                 = 3000
  protocol             = "HTTPS"
  target_type          = "ip"
  deregistration_delay = 30
  vpc_id               = module.idp_vpc.vpc_id

  health_check {
    enabled  = true
    protocol = "HTTPS"
    path     = "/ui/v2/healthy"
    matcher  = "200"
  }

  stickiness {
    type = "lb_cookie"
  }

  tags = local.core_tags

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      stickiness[0].cookie_name
    ]
  }
}

resource "aws_lb_listener" "idp" {
  load_balancer_arn = aws_lb.idp.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  certificate_arn   = aws_acm_certificate_validation.idp.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.idp["HTTP2"].arn
  }

  tags = local.core_tags
}

resource "aws_lb_listener" "idp_http_redirect" {
  load_balancer_arn = aws_lb.idp.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.core_tags
}

# Forward requests to the login UI
resource "aws_alb_listener_rule" "idp_login" {
  listener_arn = aws_lb_listener.idp.arn
  priority     = 50

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.idp_login.arn
  }

  condition {
    path_pattern {
      values = ["/ui/v2", "/ui/v2/", "/ui/v2/*"]
    }
  }

  tags = local.core_tags
}

# Send REST API endpoint requests to the HTTP1 target group
# All other requests are sent to the HTTP2 target group
resource "aws_alb_listener_rule" "idp_protocol_version" {
  listener_arn = aws_lb_listener.idp.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.idp["HTTP1"].arn
  }

  condition {
    path_pattern {
      values = [
        "/oidc/v1/userinfo",
        "/oauth/v2/keys",
        "/oauth/v2/token",
        "/.well-known/openid-configuration"
      ]
    }
  }

  tags = local.core_tags
}

# Serve security.txt as a fixed response from the ALB
resource "aws_alb_listener_rule" "security_txt" {
  listener_arn = aws_lb_listener.idp.arn
  priority     = 150

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = var.security_txt_content
      status_code  = "200"
    }
  }

  condition {
    path_pattern {
      values = ["/.well-known/security.txt"]
    }
  }

  tags = local.core_tags
}

resource "aws_lb" "idp_internal" {
  name               = "idp-internal-${var.env}"
  internal           = true
  load_balancer_type = "application"

  drop_invalid_header_fields = true
  enable_deletion_protection = true
  idle_timeout               = 60

  access_logs {
    bucket  = var.cbs_satellite_bucket_name
    prefix  = "lb_internal_logs"
    enabled = true
  }

  security_groups = [
    aws_security_group.idp_internal_lb.id
  ]
  subnets = module.idp_vpc.private_subnet_ids

  tags = local.core_tags
}

resource "aws_lb_listener" "idp_internal" {
  load_balancer_arn = aws_lb.idp_internal.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  certificate_arn   = aws_acm_certificate_validation.idp.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.idp["HTTP2"].arn
  }

  tags = local.core_tags
}