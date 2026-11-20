# Custom domain on API Gateway, in two steps (the domain's DNS lives at GoDaddy):
#  1. apply with domain_ready = false: AWS creates a free certificate and prints the DNS records
#     (output dns_records_to_add). Add them at GoDaddy; AWS issues the certificate within minutes.
#  2. apply with domain_ready = true: the sites move to www./partner./admin.<domain>; add the 3 CNAMEs printed.
locals {
  hosts = { customer = "www", partner = "partner", admin = "admin" }
  use_domain = var.domain != "" && !var.use_cloudfront
}

resource "aws_acm_certificate" "site" {
  count                     = local.use_domain ? 1 : 0
  domain_name               = "www.${var.domain}"
  subject_alternative_names = ["partner.${var.domain}", "admin.${var.domain}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_apigatewayv2_domain_name" "site" {
  for_each    = local.use_domain && var.domain_ready ? local.hosts : {}
  domain_name = "${each.value}.${var.domain}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate.site[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "site" {
  for_each    = aws_apigatewayv2_domain_name.site
  api_id      = aws_apigatewayv2_api.site[each.key].id
  domain_name = each.value.id
  stage       = aws_apigatewayv2_stage.site[each.key].id
}

output "dns_records_to_add" {
  description = "Add these CNAME records at GoDaddy (DNS > Add record). Name is without .<domain>."
  value = concat(
    local.use_domain ? [for o in aws_acm_certificate.site[0].domain_validation_options : {
      purpose = "certificate check for ${o.domain_name}"
      type    = "CNAME"
      name    = trimsuffix(o.resource_record_name, ".${var.domain}.")
      value   = trimsuffix(o.resource_record_value, ".")
    }] : [],
    [for k, d in aws_apigatewayv2_domain_name.site : {
      purpose = "${k} site"
      type    = "CNAME"
      name    = local.hosts[k]
      value   = d.domain_name_configuration[0].target_domain_name
    }],
  )
}
