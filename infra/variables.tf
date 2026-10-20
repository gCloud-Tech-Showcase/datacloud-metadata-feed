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
  description = "The GCP region for regional resources (Dataform, and the bucket if the unstructured add-on is used)"
  type        = string
  default     = "us-central1"
}

variable "dataset_location" {
  description = "BigQuery dataset location (multi-region). Also where setup.sh puts the state bucket — state is the one artifact that can't be rebuilt, so it gets the most durable home."
  type        = string
  default     = "US"
}

# [visibility:public]
variable "git_repo_url" {
  description = "GitHub repository URL the managed Dataform repo pulls from. HTTPS because the link is anonymous and tokenless, which only reaches a public repo."
  type        = string
  default     = "https://github.com/gCloud-Tech-Showcase/datacloud-metadata-feed.git"
}




variable "run_pipeline_on_apply" {
  description = "Trigger a Dataform run (compile main + workflow invocation as the runner SA) as the final step of apply and block until it finishes, so a fresh apply leaves the domain fully built. Runs once on first apply; set false to skip."
  type        = bool
  default     = true
}

variable "enable_scheduled_runs" {
  description = "Create the Dataform release + workflow configs that compile and run the pipeline hourly. Off by default so a clone-and-apply is a one-shot build with no recurring cost on a forker's project; set true for a self-refreshing deployment."
  type        = bool
  default     = false
}

