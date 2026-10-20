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
  default     = "__PROJECT_ID__"
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
  default     = "https://github.com/__GITHUB_ORG__/__REPO_NAME__.git"
}

# [visibility:private]
variable "git_repo_ssh_url" {
  description = "GitHub repository the managed Dataform repo pulls from, as an SSH remote. Deploy-key auth needs an SSH URL — 'git@host:path' or 'ssh://git@host/path'; the HTTPS form is silently unusable with a key."
  type        = string
  default     = "git@github.com:__GITHUB_ORG__/__REPO_NAME__.git"
}

# [visibility:private]
variable "deploy_key_secret_id" {
  description = "Secret Manager secret holding the private half of Dataform's SSH deploy key. Created by scripts/setup.sh, not by Tofu, so the key never lands in state. Changing this after setup.sh has run means reissuing the key."
  type        = string
  default     = "dataform-github-deploy-key"
}

# [visibility:private]
variable "git_host_public_key" {
  description = "Pinned SSH host key of the git provider, as 'ALGORITHM BASE64_KEY_VALUE'. Defaults to GitHub's ED25519 key; verify it against https://api.github.com/meta if the pull starts failing on host verification, since providers do occasionally rotate these."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
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

# [addon:unstructured]
variable "seed_data_on_apply" {
  description = "Split data/*.ndjson into per-record JSON files and upload them to the multimodal bucket as the object-table source, as a step of apply. On by default so a clone-and-apply is self-contained; set false if you seed the bucket yourself."
  type        = bool
  default     = true
}
