# =============================================================================
# VARIABLES
# Every variable has a working default, so a clone is `setup.sh` then `apply`
# with no tfvars file. `project_id`'s default below is the SINGLE SOURCE OF
# TRUTH for this domain repo: providers, resources, derived bucket names and
# scripts/setup.sh all read from it. Never restate a project ID or bucket name
# anywhere else — derive it.
# =============================================================================

variable "project_id" {
  description = "The GCP project ID (created out-of-band as a one-time prerequisite)"
  type        = string
  default     = "datacloud-metadata-feed"
}

variable "region" {
  description = "Region for every resource: datasets, aspect types, data product, feeds and functions. A data product and its assets must share one location."
  type        = string
  default     = "us-central1"
}

variable "data_product_owner" {
  description = "Owner email shown on the data product. Defaults to the deployer's email when the credentials expose it, otherwise to the functions' service account."
  type        = string
  default     = null
}
