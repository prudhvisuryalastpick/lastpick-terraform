# E-mail one-time codes through Amazon SES, sent from no-reply@<domain>.
#  1. apply: SES registers the domain; Terraform adds its 3 DKIM records in Cloudflare (domain.tf).
#  2. In the AWS console (SES > Account dashboard) request production access, so mail can go to any address.
#  3. Set the repo variable EMAIL_READY=true and apply: sign-up then requires the e-mailed code.
resource "aws_sesv2_email_identity" "domain" {
  count          = var.domain != "" ? 1 : 0
  email_identity = var.domain
}

resource "aws_iam_role_policy" "task_email" {
  count = var.domain != "" ? 1 : 0
  name  = "send-email"
  role  = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["ses:SendEmail"]
      Resource  = "*"
      Condition = { StringEquals = { "ses:FromAddress" = "no-reply@${var.domain}" } }
    }]
  })
}

locals {
  mail_from = var.domain != "" && var.email_ready ? "LastPick <no-reply@${var.domain}>" : ""
}
