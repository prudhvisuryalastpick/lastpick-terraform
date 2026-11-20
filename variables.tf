variable "region" {
  description = "AWS region. Mumbai keeps data in India."
  type        = string
  default     = "ap-south-1"
}

variable "alert_email" {
  description = "E-mail for alarms (a service down, errors, high CPU or memory, database problems). Confirm the e-mail AWS sends."
  type        = string
}

variable "vpc_cidr" {
  description = "Address range of LastPick's own VPC (kept separate from anything else in the account)."
  type        = string
  default     = "10.40.0.0/16"
}

variable "github_repo" {
  description = "owner/repo allowed to deploy through GitHub Actions (no stored AWS keys)."
  type        = string
  default     = "prudhvisuryalastpick/lastpick"
}

variable "create_github_oidc_provider" {
  description = "false if this AWS account already has the token.actions.githubusercontent.com identity provider."
  type        = bool
  default     = true
}

variable "services" {
  description = <<-EOT
    The three containers (ECS services). cpu: 256 = 0.25 vCPU, 512 = 0.5 vCPU. memory in MB.
    min/max = how many copies run; ECS adds copies when CPU stays above 60%.
  EOT
  type        = map(object({ cpu = number, memory = number, min = number, max = number }))
  default = {
    customer = { cpu = 256, memory = 512, min = 1, max = 4 }
    partner  = { cpu = 256, memory = 512, min = 1, max = 3 }
    admin    = { cpu = 256, memory = 512, min = 1, max = 1 }
  }
}

variable "use_spot" {
  description = "Extra customer/partner copies (above the first one) run on Fargate Spot, about 70% cheaper. The first copy and admin always run on regular Fargate."
  type        = bool
  default     = true
}

variable "log_days" {
  description = "Days to keep container logs."
  type        = number
  default     = 30
}

variable "db_instance_class" {
  description = "Database size."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "true keeps a standby database in a second zone (automatic failover, doubles the database cost)."
  type        = bool
  default     = false
}

variable "db_read_replica" {
  description = "A read-only copy of the database. Feeds, offer pages, dashboards and admin stats read from it, so heavy reading never slows down posting, logins or contacts. Same size as the main database (about $18/month)."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "E-mail when the month's AWS bill is forecast to pass this amount (and at 80% of it actually spent)."
  type        = number
  default     = 100
}

variable "protect_data" {
  description = <<-EOT
    true (default): the database can't be deleted by accident and a final snapshot is kept if it is.
    false: for a test setup you will tear down. `terraform destroy` then removes everything, including the
    database (no final snapshot) and the container images. Change it, run `terraform apply`, then `terraform destroy`.
  EOT
  type        = bool
  default     = true
}

variable "db_backup_days" {
  description = "Days of automatic backups / point-in-time restore."
  type        = number
  default     = 7
}

variable "admin_allowed_ips" {
  description = "Optional IP addresses allowed to open the admin panel, e.g. [\"203.0.113.10\"]. Empty = anyone may try (staff-only login still applies)."
  type        = list(string)
  default     = []
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "lastpick"
}

variable "use_cloudfront" {
  description = "true = CloudFront websites (needs an AWS account verified for CloudFront). false = API Gateway https addresses instead."
  type        = bool
  default     = false
}

variable "domain" {
  description = "Your domain (bought at GoDaddy). Sites: www.<domain> (customers), partner.<domain>, admin.<domain>. Empty = no custom domain."
  type        = string
  default     = "lastpick.in"
}

variable "domain_ready" {
  description = "Set true after the certificate's DNS records are added at GoDaddy and AWS shows the certificate as Issued."
  type        = bool
  default     = false
}
