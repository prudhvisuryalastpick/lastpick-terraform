# One private (internal) load balancer for all three services. It has no public address:
# CloudFront reaches it through a VPC origin over AWS's own network.
resource "aws_lb" "main" {
  name                       = var.name
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = aws_subnet.private[*].id
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  # anything without CloudFront's secret header, or for an unknown service, is refused here
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"Forbidden\"}"
      status_code  = "403"
    }
  }
}

# Each CloudFront distribution adds X-LastPick-Service; the load balancer sends the request to that service.
resource "aws_lb_listener_rule" "service" {
  for_each     = var.services
  listener_arn = aws_lb_listener.http.arn
  priority     = 10 + index(keys(var.services), each.key)
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }
  condition {
    http_header {
      http_header_name = "X-LastPick-Service"
      values           = [each.key]
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin.result]
    }
  }
}
