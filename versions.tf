terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.82" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # Keep Terraform's state safely in S3 (create the bucket once, then uncomment). See README.md.
  # backend "s3" {
  #   bucket       = "lastpick-terraform-state-<your-account-id>"
  #   key          = "lastpick/terraform.tfstate"
  #   region       = "ap-south-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { App = "lastpick", ManagedBy = "terraform" }
  }
}

# CloudFront-scoped resources (cache policies) are global; the provider handles them from any region.
data "aws_caller_identity" "me" {}
data "aws_availability_zones" "available" { state = "available" }
