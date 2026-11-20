# One CloudFront distribution per service: HTTPS for visitors, edge caching, DDoS protection (AWS Shield Standard).
# CloudFront reaches the private load balancer through a VPC origin, so the app is never exposed to the internet directly.
resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = "${var.name}-alb"
    arn                    = aws_lb.main.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only" # inside the VPC; switch to https-only with a certificate once the domain is bought
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}
data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_origin_request_policy" "all_viewer" { name = "Managed-AllViewerExceptHostHeader" }

# Public feeds are cached at the edge for up to 60 s (the server says 30 s), so spikes don't reach the containers.
resource "aws_cloudfront_cache_policy" "feeds" {
  name        = "${var.name}-feeds"
  default_ttl = 30
  min_ttl     = 0
  max_ttl     = 300
  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    query_strings_config { query_string_behavior = "all" }
    headers_config {
      header_behavior = "whitelist"
      headers { items = ["Origin"] }
    }
    cookies_config { cookie_behavior = "none" }
  }
}

resource "aws_cloudfront_distribution" "site" {
  for_each        = var.services
  enabled         = true
  comment         = "LastPick ${each.key}"
  http_version    = "http2and3"
  price_class     = "PriceClass_200" # includes India
  is_ipv6_enabled = true

  origin {
    origin_id   = "app"
    domain_name = aws_lb.main.dns_name
    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.alb.id
      origin_keepalive_timeout = 60
      origin_read_timeout      = 30
    }
    custom_header {
      name  = "X-LastPick-Service"
      value = each.key
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin.result
    }
  }

  default_cache_behavior {
    target_origin_id         = "app"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = true
  }

  ordered_cache_behavior {
    path_pattern           = "/assets/*" # file names change with every build, so cache for a year
    target_origin_id       = "app"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/api/offers", "/api/cities"]
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "app"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      cache_policy_id        = aws_cloudfront_cache_policy.feeds.id
      compress               = true
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  # *.cloudfront.net certificate until the domain is bought (then: ACM certificate in us-east-1 + aliases).
  viewer_certificate { cloudfront_default_certificate = true }
}
