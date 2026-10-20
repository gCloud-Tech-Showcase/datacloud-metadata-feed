# =============================================================================
# READINESS HISTORY
# The catalog aspects hold the current state. This table keeps every change,
# so the demo can show when an asset was blocked and when it was cleared.
# =============================================================================

resource "google_bigquery_table" "readiness_log" {
  dataset_id          = google_bigquery_dataset.domains["contract_monitoring"].dataset_id
  table_id            = "readiness_log"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "logged_at"
  }

  schema = jsonencode([
    { name = "logged_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "level", type = "STRING", mode = "REQUIRED", description = "ASSET or PRODUCT" },
    { name = "name", type = "STRING", mode = "REQUIRED", description = "Fully qualified name of the asset, or the data product ID" },
    { name = "status", type = "STRING", mode = "REQUIRED", description = "READY or BLOCKED" },
    { name = "reasons", type = "JSON", mode = "NULLABLE" },
    { name = "contract_version", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "current_readiness" {
  dataset_id          = google_bigquery_dataset.domains["contract_monitoring"].dataset_id
  table_id            = "current_readiness"
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT * EXCEPT (rn)
      FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY level, name ORDER BY logged_at DESC) AS rn
        FROM `${var.project_id}.${google_bigquery_table.readiness_log.dataset_id}.${google_bigquery_table.readiness_log.table_id}`
      )
      WHERE rn = 1
    SQL
  }
}
