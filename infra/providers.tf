# =============================================================================
# TERRAFORM / OPENTOFU CONFIGURATION
# Version pinning, state backend, and provider setup.
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.50.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.50.0"
    }
  }

  # State lives in gs://<project_id>-tfstate (versioned, private). The bucket is
  # deliberately NOT named here: backend blocks cannot read variables or locals,
  # so hardcoding it would duplicate project_id and break forks. Instead
  # scripts/setup.sh derives it from var.project_id's default and injects it:
  #   tofu init -backend-config="bucket=<project_id>-tfstate"
  # Run scripts/setup.sh before the first apply — it creates the bucket too.
  backend "gcs" {
    prefix = "tf/infra"
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
