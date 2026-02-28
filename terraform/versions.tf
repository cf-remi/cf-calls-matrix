terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # R2-backed remote state.
  # The state bucket must be created manually before first `terraform init`:
  #   wrangler r2 bucket create <your-tf-state-bucket>
  #
  # Then create an R2 API token in the Cloudflare dashboard with
  # "Object Read & Write" permissions on the bucket, and export:
  #   export AWS_ACCESS_KEY_ID=<r2-access-key-id>
  #   export AWS_SECRET_ACCESS_KEY=<r2-secret-access-key>
  #
  # Override bucket/key per-environment with a backend config file:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    bucket = "cf-calls-matrix-tfstate"
    key    = "terraform.tfstate"

    # Cloudflare R2 S3-compatible endpoint — replace ACCOUNT_ID
    # endpoint = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"

    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
