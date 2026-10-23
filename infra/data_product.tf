# =============================================================================
# SALES ORDERS DATA PRODUCT
# The producer domain's golden objects and the data product that publishes
# them. Editing a query below and running `tofu apply` is the schema change
# the demo detects.
# =============================================================================

locals {
  golden_tables = {
    orders = <<-SQL
      SELECT order_id, user_id, status, created_at, num_of_item
      FROM `${var.project_id}.raw.thelook_orders`
    SQL

    customers = <<-SQL
      SELECT id AS user_id, first_name, last_name, country, created_at
      FROM `${var.project_id}.raw.thelook_users`
    SQL
  }

  customer_orders_view = <<-SQL
    SELECT c.user_id, c.country, COUNT(o.order_id) AS order_count
    FROM `${var.project_id}.sales.customers` AS c
    LEFT JOIN `${var.project_id}.sales.orders` AS o USING (user_id)
    GROUP BY c.user_id, c.country
  SQL

  data_product_assets = {
    orders          = { dataset = "sales", table = "orders" }
    customers       = { dataset = "sales", table = "customers" }
    customer-orders = { dataset = "marketing", table = "customer_orders" }
  }
}

# The console's Insights tab only shows a scan's results when the table
# carries labels naming the scan. Scans created in the console add them, the
# API does not: https://cloud.google.com/bigquery/docs/generate-table-insights
# CREATE OR REPLACE drops labels, so every statement sets them again.
locals {
  insights_labels = {
    for name in concat(keys(local.golden_tables), ["customer_orders"]) : name => join(", ", [
      "(\"dataplex-data-documentation-published-scan\", \"${replace(name, "_", "-")}-insights\")",
      "(\"dataplex-data-documentation-published-project\", \"${var.project_id}\")",
      "(\"dataplex-data-documentation-published-location\", \"${var.region}\")",
    ])
  }
}

# Golden objects are built with CREATE OR REPLACE statements because:
#   - BigQuery records lineage for CREATE TABLE AS SELECT and CREATE VIEW, but
#     not for a SELECT into a destination table or a view created through the
#     API.
#   - The catalog keeps the same entry, so the schema contract aspect survives
#     a schema change. A google_bigquery_table with a schema block is replaced
#     on a dropped column instead, which deletes the entry and its aspects.
#   - Any type change is allowed, not only widening.
#
# `bq` runs the statement because google_bigquery_job returns as soon as the
# job is submitted: a failed query still shows as created. `bq` waits and fails
# the apply. Editing the SQL replaces the resource, which re-runs it.
resource "terraform_data" "golden_table" {
  for_each = local.golden_tables

  triggers_replace = [each.value]

  provisioner "local-exec" {
    command = "bq --project_id=${var.project_id} --location=${var.region} query --quiet --use_legacy_sql=false \"$DDL\""

    environment = {
      DDL = <<-SQL
        CREATE OR REPLACE TABLE `${var.project_id}.${google_bigquery_dataset.domains["sales"].dataset_id}.${each.key}`
        OPTIONS (labels = [${local.insights_labels[each.key]}])
        AS ${each.value}
      SQL
    }
  }

  depends_on = [terraform_data.copy_thelook]
}

resource "terraform_data" "customer_orders_view" {
  triggers_replace = [local.customer_orders_view]

  provisioner "local-exec" {
    command = "bq --project_id=${var.project_id} --location=${var.region} query --quiet --use_legacy_sql=false \"$DDL\""

    environment = {
      DDL = <<-SQL
        CREATE OR REPLACE VIEW `${var.project_id}.${google_bigquery_dataset.domains["marketing"].dataset_id}.customer_orders`
        OPTIONS (labels = [${local.insights_labels["customer_orders"]}])
        AS ${local.customer_orders_view}
      SQL
    }
  }

  depends_on = [terraform_data.golden_table]
}

data "google_client_openid_userinfo" "deployer" {}

resource "google_dataplex_data_product" "sales_orders" {
  location        = var.region
  data_product_id = "sales-orders"
  display_name    = "Sales Orders"
  description     = "Golden sales tables and the marketing view built on them. Every asset carries a schema contract."
  owner_emails = [coalesce(
    var.data_product_owner,
    data.google_client_openid_userinfo.deployer.email,
    google_service_account.functions.email,
  )]

  # Labels for routing notifications only. No access_group_configs are set on
  # the data assets, so these groups are not granted any access to the tables.
  dynamic "access_groups" {
    for_each = var.data_product_access_groups
    content {
      id           = access_groups.key
      group_id     = access_groups.key
      display_name = access_groups.value.display_name
      description  = access_groups.value.description

      principal {
        google_group = access_groups.value.google_group
      }
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_dataplex_data_product_data_asset" "sales_orders" {
  for_each = local.data_product_assets

  location        = var.region
  data_product_id = google_dataplex_data_product.sales_orders.data_product_id
  data_asset_id   = each.key
  resource        = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"

  depends_on = [terraform_data.golden_table, terraform_data.customer_orders_view]
}
