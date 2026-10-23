# =============================================================================
# SCHEMA CONTRACTS AND READINESS ASPECTS
# The agreed schema of every data product asset lives here, versioned in git.
# Revising a contract below and running `tofu apply` is the deliberate change
# that clears a block.
#
#   schema-contract    on each asset  = the agreed schema (written by Tofu)
#   asset-readiness    on each asset  = READY or BLOCKED + reasons (check-contract)
#   product-readiness  on the product = roll-up of its assets (rollup-product)
#
# Readiness is split into two aspect types so the readiness feed can watch
# asset-readiness alone. If the roll-up wrote the same type, its own write
# would trigger the readiness feed again.
# =============================================================================

locals {
  contracts = {
    orders = {
      dataset    = "sales"
      table      = "orders"
      entry_type = "bigquery-table"
      version    = "1"
      fields = [
        { name = "order_id", dataType = "INTEGER", mode = "NULLABLE" },
        { name = "user_id", dataType = "INTEGER", mode = "NULLABLE" },
        { name = "status", dataType = "STRING", mode = "NULLABLE" },
        { name = "created_at", dataType = "TIMESTAMP", mode = "NULLABLE" },
        { name = "num_of_item", dataType = "INTEGER", mode = "NULLABLE" },
      ]
    }

    customers = {
      dataset    = "sales"
      table      = "customers"
      entry_type = "bigquery-table"
      version    = "1"
      fields = [
        { name = "user_id", dataType = "INTEGER", mode = "NULLABLE" },
        { name = "first_name", dataType = "STRING", mode = "NULLABLE" },
        { name = "last_name", dataType = "STRING", mode = "NULLABLE" },
        { name = "country", dataType = "STRING", mode = "NULLABLE" },
        { name = "created_at", dataType = "TIMESTAMP", mode = "NULLABLE" },
      ]
    }

    customer_orders = {
      dataset    = "marketing"
      table      = "customer_orders"
      entry_type = "bigquery-view"
      version    = "1"
      fields = [
        { name = "user_id", dataType = "INTEGER", mode = "NULLABLE" },
        { name = "country", dataType = "STRING", mode = "NULLABLE" },
        { name = "order_count", dataType = "INTEGER", mode = "NULLABLE" },
      ]
    }
  }

  # Field names and types mirror the system `schema` aspect that Knowledge
  # Catalog keeps on every BigQuery entry, so the comparison is field by field.
  # Nothing here is BigQuery-specific, so a Pub/Sub topic schema could reuse it.
  field_record = {
    name = "field"
    type = "record"
    recordFields = [
      { name = "name", type = "string", index = 1, constraints = { required = true } },
      { name = "dataType", type = "string", index = 2, constraints = { required = true } },
      { name = "mode", type = "string", index = 3 },
    ]
  }

  readiness_status = {
    name = "status"
    type = "enum"
    enumValues = [
      { name = "READY", index = 1 },
      { name = "BLOCKED", index = 2 },
    ]
    index       = 1
    constraints = { required = true }
  }
}

resource "google_dataplex_aspect_type" "schema_contract" {
  location       = var.region
  aspect_type_id = "schema-contract"
  display_name   = "Schema contract"
  description    = "The schema a data product asset agreed to publish."

  metadata_template = jsonencode({
    name = "schema_contract"
    type = "record"
    recordFields = [
      { name = "version", type = "string", index = 1, constraints = { required = true } },
      { name = "fields", type = "array", index = 2, arrayItems = local.field_record },
    ]
  })

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_aspect_type" "asset_readiness" {
  location       = var.region
  aspect_type_id = "asset-readiness"
  display_name   = "Asset readiness"
  description    = "Whether the asset's live schema matches its contract, and why not."

  metadata_template = jsonencode({
    name = "asset_readiness"
    type = "record"
    recordFields = [
      local.readiness_status,
      { name = "checkedAt", type = "datetime", index = 2 },
      { name = "contractVersion", type = "string", index = 3 },
      {
        name  = "reasons"
        type  = "array"
        index = 4
        arrayItems = {
          name = "reason"
          type = "record"
          recordFields = [
            { name = "change", type = "string", index = 1 },
            { name = "column", type = "string", index = 2 },
            { name = "detail", type = "string", index = 3 },
            { name = "breaking", type = "bool", index = 4 },
          ]
        }
      },
    ]
  })

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_aspect_type" "product_readiness" {
  location       = var.region
  aspect_type_id = "product-readiness"
  display_name   = "Product readiness"
  description    = "BLOCKED when any asset in the data product is not READY."

  metadata_template = jsonencode({
    name = "product_readiness"
    type = "record"
    recordFields = [
      local.readiness_status,
      { name = "checkedAt", type = "datetime", index = 2 },
      {
        name  = "reasons"
        type  = "array"
        index = 3
        arrayItems = {
          name = "reason"
          type = "record"
          recordFields = [
            { name = "asset", type = "string", index = 1 },
            { name = "detail", type = "string", index = 2 },
          ]
        }
      },
    ]
  })

  depends_on = [time_sleep.api_propagation]
}

data "google_project" "current" {}

# BigQuery entries are created by Knowledge Catalog, not by Tofu. On an
# `@bigquery` entry the provider only patches the aspects listed here, leaves
# the readiness aspects written by the functions alone, and on destroy drops
# the entry from state without deleting it.
resource "google_dataplex_entry" "contract" {
  for_each = local.contracts

  project              = data.google_project.current.number
  location             = var.region
  entry_group_id       = "@bigquery"
  entry_id             = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"
  entry_type           = "${local.dataplex_types}/entryTypes/${each.value.entry_type}"
  fully_qualified_name = "bigquery:${var.project_id}.${each.value.dataset}.${each.value.table}"
  parent_entry         = "projects/${data.google_project.current.number}/locations/${var.region}/entryGroups/@bigquery/entries/bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}"

  aspects {
    aspect_key = "${data.google_project.current.number}.${var.region}.${google_dataplex_aspect_type.schema_contract.aspect_type_id}"
    aspect {
      data = jsonencode({
        version = each.value.version
        fields  = each.value.fields
      })
    }
  }

  depends_on = [
    google_dataplex_data_product_data_asset.sales_orders,
    time_sleep.feed_activation,
  ]
}
