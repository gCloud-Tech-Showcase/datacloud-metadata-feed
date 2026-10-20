# =============================================================================
# STORAGE + BQ->VERTEX CONNECTION
# Part of the GCS + BigLake + Gemini add-on ([addon:*]) — init.sh deletes this
# whole file when the domain doesn't need it, so nothing in here is tagged
# line-by-line. (Wildcard, so the tag stripper can't eat this line.)
#
# The corpus lives as one JSON file per record in a private GCS bucket, and a
# BigLake object table reads it (one row per file). The same BigQuery connection
# both reads those files (storage.objectViewer) and calls Gemini for the remote
# model (aiplatform.user). Data is seeded by scripts/seed_data.sh at apply.
# =============================================================================

# -----------------------------------------------------------------------------
# Multimodal bucket — object-table source. Name is <project>-multimodal-data so
# the object-table URI (derived from defaultDatabase in SQL) resolves to it.
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "multimodal_data" {
  name     = "${var.project_id}-multimodal-data"
  location = var.region

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # The corpus is fully reproducible from the committed data/*.ndjson, so
  # let `tofu destroy` clean the bucket up (departs from the monorepo's false).
  force_destroy = true

  labels = {
    project = "__REPO_NAME__"
    purpose = "unstructured-data"
    domain  = "__DOMAIN_SLUG__"
  }

  depends_on = [google_project_service.apis["storage.googleapis.com"]]
}

# -----------------------------------------------------------------------------
# BigQuery connection to Vertex AI / GCS (cloud-resource, holds a managed SA).
# Referenced verbatim in SQL as `US.vertex-ai-connection`.
# -----------------------------------------------------------------------------

resource "google_bigquery_connection" "vertex_ai" {
  connection_id = "vertex-ai-connection"
  location      = var.dataset_location
  friendly_name = "Vertex AI Connection for Gemini"
  description   = "BigQuery connection for Gemini remote models and BigLake object tables"

  cloud_resource {}

  depends_on = [
    google_project_service.apis["bigqueryconnection.googleapis.com"],
    google_project_service.apis["aiplatform.googleapis.com"],
  ]
}

# The connection's delegated cloud-resource SA is materialized ASYNCHRONOUSLY by
# Google after the connection resource returns. depends_on guarantees the
# connection exists, NOT that its SA identity has propagated into IAM — so the
# grants below can 400 "service account does not exist" on a fresh apply. Brief
# buffer to absorb that propagation lag (idempotent: only waits on create).
resource "time_sleep" "wait_connection_sa" {
  depends_on      = [google_bigquery_connection.vertex_ai]
  create_duration = "30s"
}

# Connection SA can call Gemini (remote model inference, incl. the global endpoint).
resource "google_project_iam_member" "bq_connection_vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.vertex_ai.cloud_resource[0].service_account_id}"

  depends_on = [time_sleep.wait_connection_sa]
}

# Connection SA can read the source files backing the object table.
resource "google_storage_bucket_iam_member" "bq_connection_gcs_reader" {
  bucket = google_storage_bucket.multimodal_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.vertex_ai.cloud_resource[0].service_account_id}"

  depends_on = [time_sleep.wait_connection_sa]
}

# The Dataform runner SA is the query identity for ML.GENERATE_TEXT, which
# delegates to the connection's own SA. Remote-model inference requires
# bigquery.connections.delegate for the QUERYING identity — and only
# roles/bigquery.connectionAdmin carries it (connectionUser has get/use but NOT
# delegate, despite the name). Scoped to this single connection, so it admins
# only this connection rather than the project.
#
# Lives here, with the connection, rather than in dataform.tf: it exists only
# because this domain has a connection, so it belongs to the storage add-on and
# is removed along with it.
resource "google_bigquery_connection_iam_member" "runner_connection_admin" {
  project       = var.project_id
  location      = google_bigquery_connection.vertex_ai.location
  connection_id = google_bigquery_connection.vertex_ai.connection_id
  role          = "roles/bigquery.connectionAdmin"
  member        = "serviceAccount:${google_service_account.dataform_runner.email}"
}
