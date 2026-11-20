# HTTPS addresses without CloudFront: one API Gateway HTTP API per service
# (https://<id>.execute-api.ap-south-1.amazonaws.com). It reaches the private load balancer through a
# VPC link, so the app stays off the public internet, and it adds the same two headers CloudFront would.
# Also gives per-site rate limits. Used while var.use_cloudfront is false.

resource "aws_security_group" "apigw" {
  name        = "${var.name}-apigw"
  description = "LastPick API Gateway VPC link"
  vpc_id      = aws_vpc.main.id
  egress {
    description = "Load balancer"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_apigatewayv2_vpc_link" "main" {
  count              = var.use_cloudfront ? 0 : 1
  name               = var.name
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.apigw.id]
}

resource "aws_apigatewayv2_api" "site" {
  for_each      = var.use_cloudfront ? {} : var.services
  name          = "${var.name}-${each.key}"
  protocol_type = "HTTP"
  description   = "LastPick ${each.key}"
}

resource "aws_apigatewayv2_integration" "site" {
  for_each           = aws_apigatewayv2_api.site
  api_id             = each.value.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.http.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main[0].id
  timeout_milliseconds = 30000
  request_parameters = {
    "overwrite:header.X-LastPick-Service" = each.key
    "overwrite:header.X-Origin-Verify"    = random_password.origin.result
    # the visitor's IP, as CloudFront would send it (the load balancer appends one more hop)
    "overwrite:header.X-Forwarded-For" = "$context.identity.sourceIp"
  }
}

resource "aws_apigatewayv2_route" "site" {
  for_each  = aws_apigatewayv2_api.site
  api_id    = each.value.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.site[each.key].id}"
}

resource "aws_apigatewayv2_stage" "site" {
  for_each    = aws_apigatewayv2_api.site
  api_id      = each.value.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_rate_limit  = each.key == "admin" ? 20 : 200 # requests per second for the whole site
    throttling_burst_limit = each.key == "admin" ? 40 : 400
  }
}

# Public address of each site: your domain when ready, else CloudFront when on, else the API Gateway address.
locals {
  site_url = { for k in keys(var.services) : k => try(
    "https://${aws_apigatewayv2_domain_name.site[k].domain_name}",
    "https://${aws_cloudfront_distribution.site[k].domain_name}",
    trimsuffix(aws_apigatewayv2_stage.site[k].invoke_url, "/"),
  ) }
}
