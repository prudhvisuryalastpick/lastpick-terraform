terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.82" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.48" }
  }

  # State is kept in S3. The bucket and key are passed at init time (-backend-config); the
  # "Infrastructure" GitHub workflow creates the bucket lastpick-terraform-state-<account-id> automatically.
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { App = "lastpick", ManagedBy = "terraform" }
  }
}

# Cloudflare (DNS, caching, HTTPS for the sites). The API token comes from the CLOUDFLARE_API_TOKEN repo secret.
provider "cloudflare" {}

# CloudFront-scoped resources (cache policies) are global; the provider handles them from any region.
data "aws_caller_identity" "me" {}
data "aws_availability_zones" "available" { state = "available" }
