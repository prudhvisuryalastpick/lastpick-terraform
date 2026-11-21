# The domain's DNS is on Cloudflare (free plan). Terraform creates every record itself, so nothing is copied by hand:
#   - the AWS certificate check records (the certificate is issued in the same apply)
#   - customer./partner./admin.<domain> -> the load balancer, through Cloudflare (proxied: cached, free data)
#   - <domain> and www.<domain> -> redirect to https://customer.<domain>
#   - e-mail signing (DKIM) records for Amazon SES
# One-time setup by the owner: add the site to Cloudflare, switch the nameservers at GoDaddy, and save a Cloudflare
# API token as the repo secret CLOUDFLARE_API_TOKEN (see README).
locals {
  hosts    = { customer = "customer", partner = "partner", admin = "admin" }
  site_url = { for k, h in local.hosts : k => "https://${h}.${var.domain}" }
}

data "cloudflare_zone" "main" {
  name = var.domain
}

# ---------- certificate (free, from AWS) for the load balancer ----------
resource "aws_acm_certificate" "site" {
  domain_name               = "customer.${var.domain}"
  subject_alternative_names = ["partner.${var.domain}", "admin.${var.domain}", "www.${var.domain}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "cloudflare_record" "cert" {
  for_each = { for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o }
  zone_id         = data.cloudflare_zone.main.id
  name            = trimsuffix(each.value.resource_record_name, ".")
  type            = each.value.resource_record_type
  content         = trimsuffix(each.value.resource_record_value, ".")
  proxied         = false
  ttl             = 300
  allow_overwrite = true
  comment         = "AWS certificate check for ${each.key}"
}

resource "aws_acm_certificate_validation" "site" {
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in cloudflare_record.cert : r.hostname]
}

# ---------- the three sites ----------
resource "cloudflare_record" "site" {
  for_each        = local.hosts
  zone_id         = data.cloudflare_zone.main.id
  name            = each.value
  type            = "CNAME"
  content         = aws_lb.main.dns_name
  proxied         = true # through Cloudflare: cached, protected, data to phones is free
  ttl             = 1
  allow_overwrite = true
  comment         = "LastPick ${each.key} site"
}

# lastpick.in and www.lastpick.in only redirect, so they just need to exist behind Cloudflare
resource "cloudflare_record" "root" {
  for_each        = toset([var.domain, "www"])
  zone_id         = data.cloudflare_zone.main.id
  name            = each.value
  type            = "CNAME"
  content         = aws_lb.main.dns_name
  proxied         = true
  ttl             = 1
  allow_overwrite = true
  comment         = "redirects to the customer site"
}

resource "cloudflare_ruleset" "redirect" {
  zone_id = data.cloudflare_zone.main.id
  name    = "LastPick redirects"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"
  rules {
    description = "lastpick.in and www -> customer site"
    expression  = "(http.host in {\"${var.domain}\" \"www.${var.domain}\"})"
    action      = "redirect"
    action_parameters {
      from_value {
        status_code = 301
        target_url {
          value = "https://customer.${var.domain}"
        }
        preserve_query_string = false
      }
    }
    enabled = true
  }
}

# Cloudflare adds the secret header on the way to AWS; the load balancer and the app refuse requests without it.
resource "cloudflare_ruleset" "origin_header" {
  zone_id = data.cloudflare_zone.main.id
  name    = "LastPick origin header"
  kind    = "zone"
  phase   = "http_request_late_transform"
  rules {
    description = "prove the request came through Cloudflare"
    expression  = "(http.host in {\"customer.${var.domain}\" \"partner.${var.domain}\" \"admin.${var.domain}\"})"
    action      = "rewrite"
    action_parameters {
      headers {
        name      = "X-Origin-Verify"
        operation = "set"
        value     = random_password.origin.result
      }
    }
    enabled = true
  }
}

# Public offer lists are the same for everyone nearby: Cloudflare keeps each for as long as the app says (60 s).
resource "cloudflare_ruleset" "cache" {
  zone_id = data.cloudflare_zone.main.id
  name    = "LastPick caching"
  kind    = "zone"
  phase   = "http_request_cache_settings"
  rules {
    description = "cache public offer lists"
    expression  = "(http.request.uri.path eq \"/api/offers\" and http.request.method eq \"GET\")"
    action      = "set_cache_settings"
    action_parameters {
      cache = true
      edge_ttl {
        mode = "respect_origin"
      }
      browser_ttl {
        mode = "respect_origin"
      }
    }
    enabled = true
  }
}

resource "cloudflare_zone_settings_override" "main" {
  zone_id = data.cloudflare_zone.main.id
  settings {
    ssl              = "strict" # Cloudflare checks the AWS certificate
    always_use_https = "on"
    min_tls_version  = "1.2"
    brotli           = "on"
  }
}

# ---------- e-mail signing (DKIM) for Amazon SES: always 3 records ----------
resource "cloudflare_record" "dkim" {
  count           = 3
  zone_id         = data.cloudflare_zone.main.id
  name            = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey"
  type            = "CNAME"
  content         = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  proxied         = false
  ttl             = 300
  allow_overwrite = true
  comment         = "Amazon SES e-mail signing"
}
