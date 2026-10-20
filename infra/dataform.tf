# =============================================================================
# DATAFORM
# Service identity, execution SA and IAM, plus the optional release/workflow
# schedule and the first-run trigger. Everything here is the same whether the
# GitHub repo is public or private.
#
# The git link itself is NOT here — it's the one part that differs, so it lives
# in a file of its own and init.sh keeps exactly one of the two:
#   dataform_git_public.tf   anonymous, tokenless  (public repo)
#   dataform_git_private.tf  SSH deploy key        (private repo)
# Both create a Dataform repository named local.dataform_repository_name, which
# is why the resources below can reference it as a plain string and only need an
# ordering edge. The [visibility:*]-tagged `depends_on` entries below are that
# edge — init.sh keeps only the one naming the file that survived.
#
# The repo must already contain this code on `main` before `tofu apply`.
# =============================================================================

locals {
  dataform_repository_name = "__REPO_NAME__"
}

# -----------------------------------------------------------------------------
# Dataform Service Identity
# -----------------------------------------------------------------------------

resource "google_project_service_identity" "dataform" {
  provider = google-beta
  project  = var.project_id
  service  = "dataform.googleapis.com"

  depends_on = [google_project_service.apis["dataform.googleapis.com"]]
}

# -----------------------------------------------------------------------------
# Dataform execution service account
# Workflow invocations run AS this SA. Newly created projects enforce "strict
# act-as" IAM checks, which require the workflow_config to name an explicit
# execution SA (the Dataform service agent alone is not accepted). This SA holds
# the BigQuery + Vertex permissions the pipeline needs; the Dataform service
# agent is granted actAs on it so Dataform can impersonate it at run time.
# -----------------------------------------------------------------------------

resource "google_service_account" "dataform_runner" {
  account_id   = "dataform-runner"
  display_name = "Dataform workflow execution"

  depends_on = [google_project_service.apis["iam.googleapis.com"]]
}

resource "google_project_iam_member" "runner_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataform_runner.email}"
}

# dataViewer is not needed — dataEditor is a superset that includes read access.
resource "google_project_iam_member" "runner_bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.dataform_runner.email}"
}

# Lets the pipeline reach Vertex at run time — required both for BQML models
# registered in the Model Registry (model_registry='vertex_ai'), where
# registration fails after training without it, and for any Gemini call from
# BigQuery. Drop only if the domain is pure SQL with no model of either kind.
resource "google_project_iam_member" "runner_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.dataform_runner.email}"
}

# Let the Dataform service agent impersonate the runner SA.
# - serviceAccountUser (actAs): required at config time to name the SA on the
#   workflow_config under strict act-as checks.
# - serviceAccountTokenCreator (getAccessToken): required at run time so Dataform
#   can mint tokens for the runner and execute the workflow as it.
resource "google_service_account_iam_member" "dataform_impersonate_runner" {
  for_each = toset([
    "roles/iam.serviceAccountUser",
    "roles/iam.serviceAccountTokenCreator",
  ])
  service_account_id = google_service_account.dataform_runner.name
  role               = each.value
  member             = "serviceAccount:${google_project_service_identity.dataform.email}"
}

# -----------------------------------------------------------------------------
# Dataform Release Configuration (optional — enable_scheduled_runs)
# Compiles `main` hourly. default_database overrides workflow_settings.yaml's
# defaultProject server-side, so forkers get their own project without editing YAML.
# -----------------------------------------------------------------------------

resource "google_dataform_repository_release_config" "main" {
  count = var.enable_scheduled_runs ? 1 : 0

  provider   = google-beta
  project    = var.project_id
  region     = var.region
  repository = local.dataform_repository_name

  name          = "production"
  git_commitish = "main"

  cron_schedule = "0 * * * *"
  time_zone     = "America/Los_Angeles"

  code_compilation_config {
    default_database = var.project_id
    default_location = var.dataset_location
  }

  depends_on = [
    terraform_data.repository,       # [visibility:public]
    google_dataform_repository.this, # [visibility:private]
  ]
}

# -----------------------------------------------------------------------------
# Dataform Workflow Configuration (optional — enable_scheduled_runs)
# -----------------------------------------------------------------------------

resource "google_dataform_repository_workflow_config" "main" {
  count = var.enable_scheduled_runs ? 1 : 0

  provider       = google-beta
  project        = var.project_id
  region         = var.region
  repository     = local.dataform_repository_name
  release_config = google_dataform_repository_release_config.main[0].id

  name = "full-workflow"

  # Execute hourly, 15 min after the release config compiles main (a release
  # config only produces compilation results — this is what actually runs the
  # DAG). Dial back or remove to stop the pipeline self-refreshing.
  cron_schedule = "15 * * * *"
  time_zone     = "America/Los_Angeles"

  invocation_config {
    service_account                          = google_service_account.dataform_runner.email
    fully_refresh_incremental_tables_enabled = true
    transitive_dependencies_included         = true
    transitive_dependents_included           = false
  }

  depends_on = [google_service_account_iam_member.dataform_impersonate_runner]
}

# -----------------------------------------------------------------------------
# First-run trigger (optional)
# There is no declarative Terraform resource for a Dataform workflow invocation,
# so kick the first run off imperatively at the end of apply and block until it
# finishes — a fresh apply then leaves the domain fully built instead of waiting
# up to an hour for the workflow cron. Runs once (on create); subsequent applies
# are no-ops. Disable with run_pipeline_on_apply = false.
# -----------------------------------------------------------------------------

resource "terraform_data" "run_pipeline" {
  count = var.run_pipeline_on_apply ? 1 : 0

  # The auto-run creates its own compilation result + workflow invocation via
  # REST, so it's independent of the (optional) scheduled configs. It needs the
  # repository to compile from, the runner's BigQuery/Vertex grants, and the
  # service agent's impersonation rights over the runner.
  #
  # Terraform can't add a dependency edge from outside a resource, so an add-on
  # that must run BEFORE the pipeline has to be listed here. The two lines below
  # the marker belong to the unstructured add-on: delete them with it, keep them
  # with it. Without the seed edge the pipeline queries an empty bucket; without
  # the connection-admin edge ML.GENERATE_TEXT fails on a missing delegate
  # permission — and IAM propagation makes both look like flaky races.
  depends_on = [
    terraform_data.repository,       # [visibility:public]
    google_dataform_repository.this, # [visibility:private]
    google_service_account_iam_member.dataform_impersonate_runner,
    google_project_iam_member.runner_bq_job_user,
    google_project_iam_member.runner_bq_data_editor,
    google_project_iam_member.runner_vertex_ai_user,
    # __ADDON_PIPELINE_DEPS__
    terraform_data.seed_data,
    google_bigquery_connection_iam_member.runner_connection_admin,
  ]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/run_pipeline.sh"
    environment = {
      PROJECT   = var.project_id
      REGION    = var.region
      REPO      = local.dataform_repository_name
      RUNNER_SA = google_service_account.dataform_runner.email
    }
  }
}
