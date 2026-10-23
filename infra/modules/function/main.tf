# =============================================================================
# CLOUD FUNCTION (GEN2) RECEIVING PUB/SUB PUSHES
# One HTTP function, reachable only from inside the project, invocable only by
# the push identity passed in.
# =============================================================================

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

variable "name" {
  description = "Function name, also the name of the Cloud Run service behind it"
  type        = string
}

variable "region" {
  description = "Region for the function"
  type        = string
}

variable "entry_point" {
  description = "Python function that handles the request"
  type        = string
}

variable "source_bucket" {
  description = "Bucket holding the zipped source"
  type        = string
}

variable "source_object" {
  description = "Object name of the zipped source"
  type        = string
}

variable "build_service_account" {
  description = "Full resource ID of the service account Cloud Build runs as"
  type        = string
}

variable "runtime_service_account" {
  description = "Email of the service account the function runs as"
  type        = string
}

variable "invoker_member" {
  description = "IAM member allowed to invoke the function (the Pub/Sub push identity)"
  type        = string
}

variable "max_instances" {
  description = "Upper bound on concurrent instances"
  type        = number
}

variable "environment" {
  description = "Environment variables for the function"
  type        = map(string)
}

resource "google_cloudfunctions2_function" "this" {
  name     = var.name
  location = var.region

  build_config {
    runtime         = "python312"
    entry_point     = var.entry_point
    service_account = var.build_service_account

    source {
      storage_source {
        bucket = var.source_bucket
        object = var.source_object
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 60
    min_instance_count    = 0
    max_instance_count    = var.max_instances
    service_account_email = var.runtime_service_account
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    environment_variables = var.environment
  }

  labels = { domain = "metadata-feed" }
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  location = var.region
  name     = google_cloudfunctions2_function.this.service_config[0].service
  role     = "roles/run.invoker"
  member   = var.invoker_member
}

output "uri" {
  description = "HTTPS endpoint for the push subscription"
  value       = google_cloudfunctions2_function.this.service_config[0].uri
}
