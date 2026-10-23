# =============================================================================
# SOURCE DATA
# theLook eCommerce lives in the US multi-region. BigQuery cannot query across
# locations, so a CREATE TABLE AS SELECT into us-central1 fails. A cross-region
# table copy works, so the source tables are copied into `raw` first.
# =============================================================================

# Prefixed so the catalog never shows two tables called `orders`.
locals {
  thelook_tables = {
    orders = "thelook_orders"
    users  = "thelook_users"
  }
}

# `bq cp` waits for the copy to finish and fails the apply if it does not.
# google_bigquery_job returns as soon as the job is submitted, so the golden
# queries could start before `raw` exists.
resource "terraform_data" "copy_thelook" {
  for_each = local.thelook_tables

  triggers_replace = [google_bigquery_dataset.domains["raw"].id, each.value]

  provisioner "local-exec" {
    command = "bq --project_id=${var.project_id} cp --force bigquery-public-data:thelook_ecommerce.${each.key} ${var.project_id}:${google_bigquery_dataset.domains["raw"].dataset_id}.${each.value}"
  }
}
