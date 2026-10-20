# =============================================================================
# DATAFORM GIT LINK — PUBLIC REPO
# The PUBLIC half of the [visibility:*] pair — init.sh deletes this whole file
# for a private domain and keeps dataform_git_private.tf instead. Exactly one of
# the two survives. (Wildcard, so the tag stripper can't eat this line.)
#
# The repository pulls compiled SQL from git_repo_url ANONYMOUSLY: no PAT, no
# deploy key, no Secret Manager anywhere in the dependency graph. An anonymous
# link only reaches a public repo, which is the whole reason the two paths are
# separate files.
#
# Created via the Dataform REST API (a terraform_data provisioner) rather than
# google_dataform_repository, because the provider enforces
# ExactlyOneOf(token / ssh / developer-connect) on git_remote_settings and so
# cannot express a tokenless link, even though the REST API accepts one. The
# private path has no such problem and is an ordinary resource.
#
# create : idempotent GET-then-POST with a tokenless git_remote_settings.
# destroy: DELETE ?force=true so `tofu destroy` cleans it up.
# All values the destroy provisioner needs live in `input` (destroy-time
# provisioners may only reference `self`), and any change recreates the repo.
# =============================================================================

resource "terraform_data" "repository" {
  triggers_replace = {
    name   = local.dataform_repository_name
    region = var.region
    url    = var.git_repo_url
  }

  input = {
    project = var.project_id
    region  = var.region
    name    = local.dataform_repository_name
    url     = var.git_repo_url
    script  = "${path.module}/scripts/manage_repository.sh"
  }

  depends_on = [
    google_project_service_identity.dataform,
    google_project_service.apis["dataform.googleapis.com"],
  ]

  provisioner "local-exec" {
    command = "bash ${self.input.script} create"
    environment = {
      PROJECT = self.input.project
      REGION  = self.input.region
      REPO    = self.input.name
      URL     = self.input.url
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash ${self.input.script} delete"
    environment = {
      PROJECT = self.input.project
      REGION  = self.input.region
      REPO    = self.input.name
    }
  }
}
