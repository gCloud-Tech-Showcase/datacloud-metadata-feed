# =============================================================================
# DATA PROFILE, DATA QUALITY AND INSIGHTS SCANS
# Every scan publishes its result to the asset's catalog entry, next to the
# schema contract and readiness aspects. Scans are on demand: one run starts
# when the scan is created, and `gcloud dataplex datascans run` re-runs one.
# Profile and quality results appear in the console from the catalog alone.
# Insights also need labels on the BigQuery table that name the scan, which
# the CREATE OR REPLACE statements in data_product.tf set.
#
#   profile   per-column statistics (data_profile_spec)
#   quality   pass/fail rules (data_quality_spec)
#   insights  Gemini-generated descriptions and sample queries
#             (data_documentation_spec, shown as "Insights" in the console)
# =============================================================================

locals {
  scanned_assets = {
    orders          = "sales"
    customers       = "sales"
    customer_orders = "marketing"
  }

  quality_rules = {
    orders = [
      { column = "order_id", dimension = "COMPLETENESS", kind = "non_null" },
      { column = "order_id", dimension = "UNIQUENESS", kind = "unique" },
      { column = "user_id", dimension = "COMPLETENESS", kind = "non_null" },
      { column = "num_of_item", dimension = "COMPLETENESS", kind = "non_null" },
      { column = "num_of_item", dimension = "VALIDITY", kind = "range", min = "1", max = "10" },
      { column = "status", dimension = "VALIDITY", kind = "set", values = ["Processing", "Shipped", "Complete", "Cancelled", "Returned"] },
    ]

    customers = [
      { column = "user_id", dimension = "COMPLETENESS", kind = "non_null" },
      { column = "user_id", dimension = "UNIQUENESS", kind = "unique" },
      { column = "country", dimension = "COMPLETENESS", kind = "non_null" },
    ]

    customer_orders = [
      { column = "user_id", dimension = "COMPLETENESS", kind = "non_null" },
      { column = "user_id", dimension = "UNIQUENESS", kind = "unique" },
      { column = "order_count", dimension = "VALIDITY", kind = "range", min = "0", max = "1000" },
    ]
  }

  scans = merge(
    { for t, ds in local.scanned_assets : "${replace(t, "_", "-")}-profile" => { table = t, dataset = ds, kind = "profile" } },
    { for t, ds in local.scanned_assets : "${replace(t, "_", "-")}-quality" => { table = t, dataset = ds, kind = "quality" } },
    { for t, ds in local.scanned_assets : "${replace(t, "_", "-")}-insights" => { table = t, dataset = ds, kind = "insights" } },
  )
}

resource "google_service_account" "data_scanner" {
  account_id   = "data-scanner"
  display_name = "Identity the profile, quality and insights scans run as"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "data_scanner_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.data_scanner.member
}

# Scans with a custom identity run as the Dataplex service agent impersonating
# that identity.
resource "google_service_account_iam_member" "dataplex_impersonates_scanner" {
  service_account_id = google_service_account.data_scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.dataplex.member
}

# Profile and quality scans failed with an impersonation error for more than
# 60 seconds after the grant. Insights scans with the same identity did not.
resource "time_sleep" "scanner_iam_propagation" {
  create_duration = "3m"

  depends_on = [
    google_service_account_iam_member.dataplex_impersonates_scanner,
    google_project_iam_member.data_scanner_job_user,
    google_bigquery_dataset_iam_member.data_scanner_viewer,
    time_sleep.api_propagation,
  ]
}

resource "google_bigquery_dataset_iam_member" "data_scanner_viewer" {
  for_each = toset(["sales", "marketing"])

  dataset_id = google_bigquery_dataset.domains[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.data_scanner.member
}

resource "google_dataplex_datascan" "scan" {
  for_each = local.scans

  location     = var.region
  data_scan_id = each.key
  display_name = "${each.value.dataset}.${each.value.table} ${each.value.kind}"

  data {
    resource = "//bigquery.googleapis.com/projects/${var.project_id}/datasets/${each.value.dataset}/tables/${each.value.table}"
  }

  execution_spec {
    trigger {
      on_demand {}
    }
  }

  execution_identity {
    service_account {
      email = google_service_account.data_scanner.email
    }
  }

  dynamic "data_profile_spec" {
    for_each = each.value.kind == "profile" ? [1] : []
    content {
      catalog_publishing_enabled = true
    }
  }

  dynamic "data_quality_spec" {
    for_each = each.value.kind == "quality" ? [1] : []
    content {
      catalog_publishing_enabled = true

      dynamic "rules" {
        for_each = local.quality_rules[each.value.table]
        content {
          column    = rules.value.column
          dimension = rules.value.dimension

          dynamic "non_null_expectation" {
            for_each = rules.value.kind == "non_null" ? [1] : []
            content {}
          }

          dynamic "uniqueness_expectation" {
            for_each = rules.value.kind == "unique" ? [1] : []
            content {}
          }

          dynamic "range_expectation" {
            for_each = rules.value.kind == "range" ? [1] : []
            content {
              min_value = rules.value.min
              max_value = rules.value.max
            }
          }

          dynamic "set_expectation" {
            for_each = rules.value.kind == "set" ? [1] : []
            content {
              values = rules.value.values
            }
          }
        }
      }
    }
  }

  dynamic "data_documentation_spec" {
    for_each = each.value.kind == "insights" ? [1] : []
    content {
      catalog_publishing_enabled = true
    }
  }

  labels = { domain = "metadata-feed" }

  # With the Gemini Data Analytics API off, creating the insights scan on the
  # view took 13 to 21 minutes on a fresh project (2026-10-26). Tofu gave up
  # after its default 5 minutes while the create carried on, so the scan never
  # reached state and every later apply failed with 409 already exists. With
  # the API on, every scan was created in under 3 minutes. The longer timeout
  # keeps a slow create from leaving the state behind.
  timeouts {
    create = "30m"
  }

  depends_on = [
    terraform_data.golden_table,
    terraform_data.customer_orders_view,
    time_sleep.scanner_iam_propagation,
  ]
}

# Starts the first run, so results are in the catalog when the apply finishes.
# Insights run after the profiles because Gemini grounds its descriptions in
# profile results when they exist.
resource "terraform_data" "first_scan_run" {
  for_each = { for k, v in local.scans : k => v if v.kind != "insights" }

  triggers_replace = [google_dataplex_datascan.scan[each.key].id]

  provisioner "local-exec" {
    command = "gcloud dataplex datascans run ${each.key} --location=${var.region} --project=${var.project_id} --format=none"
  }
}

resource "time_sleep" "profile_results" {
  create_duration = "3m"

  depends_on = [terraform_data.first_scan_run]
}

resource "terraform_data" "first_insights_run" {
  for_each = { for k, v in local.scans : k => v if v.kind == "insights" }

  triggers_replace = [google_dataplex_datascan.scan[each.key].id]

  provisioner "local-exec" {
    command = "gcloud dataplex datascans run ${each.key} --location=${var.region} --project=${var.project_id} --format=none"
  }

  depends_on = [time_sleep.profile_results]
}
