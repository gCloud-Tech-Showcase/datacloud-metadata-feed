# =============================================================================
# DATA SEEDING
# Part of the GCS + BigLake + Gemini add-on ([addon:*]) — init.sh deletes this
# whole file when the domain doesn't need it, along with storage.tf, scripts/ and
# data/, and strips the matching tagged lines elsewhere. Nothing to do by hand.
# (Wildcard, so the tag stripper can't eat this line.)
#
# Splits data/*.ndjson into one JSON file per record and uploads them, because a
# BigLake object table is ONE ROW PER FILE. Uploading the NDJSON as a single
# blob collapses it to one row and breaks per-record analysis — that is the
# entire reason this step exists rather than just copying the corpus up.
# =============================================================================

resource "terraform_data" "seed_data" {
  count = var.seed_data_on_apply ? 1 : 0

  depends_on = [
    google_storage_bucket.multimodal_data,
    google_storage_bucket_iam_member.bq_connection_gcs_reader,
    google_project_iam_member.bq_connection_vertex_ai_user,
  ]

  # `gsutil rsync -d` makes re-applies idempotent — the bucket reconciles to
  # exactly the corpus committed under data/.
  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/seed_data.sh"
    environment = {
      PROJECT = var.project_id
    }
  }
}
