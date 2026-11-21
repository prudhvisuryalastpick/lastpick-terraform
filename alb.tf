# One public load balancer for all three services, reachable ONLY from Cloudflare (security group: Cloudflare's
# address ranges; requests must also carry the secret header Cloudflare adds). Cloudflare caches public offer lists
# and serves the data to phones for free, so most traffic never reaches AWS.
resource "aws_lb" "main" {
  name                       = var.name
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = 60 # the server keeps connections open 65 s, longer than this
  drop_invalid_header_fields = true
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "service" {
  for_each             = var.services
  name                 = "${var.name}-${each.key}"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 20
  health_check {
    path                = "/healthz" # 200 only when the container can reach the database
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

# HTTPS with the free AWS certificate (Cloudflare connects in "Full (strict)" mode and checks it).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.site.certificate_arn
  # anything without Cloudflare's secret header, or for an unknown address, is refused here
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"Forbidden\"}"
      status_code  = "403"
    }
  }
}

# customer.<domain> -> customer service, partner.<domain> -> partner, admin.<domain> -> admin.
# The service name header is set here for the app, so nothing outside can choose it.
resource "aws_lb_listener_rule" "service" {
  for_each     = var.services
  listener_arn = aws_lb_listener.https.arn
  priority     = 10 + index(keys(var.services), each.key)
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }
  condition {
    host_header {
      values = ["${local.hosts[each.key]}.${var.domain}"]
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin.result]
    }
  }
}
