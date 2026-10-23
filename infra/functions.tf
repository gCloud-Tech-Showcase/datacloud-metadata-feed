# =============================================================================
# CLOUD FUNCTIONS
#
#   check-contract   compares an asset's live schema with its contract and
#                    writes asset-readiness
#   rollup-product   recomputes product-readiness for every data product that
#                    contains the asset
#   notify-stewards  publishes a schema change notification for every data
#                    product that contains the asset
#
# All three receive Pub/Sub pushes, authenticated with the push-invoker
# identity.
# =============================================================================

locals {
  functions = {
    check-contract  = "check_contract"
    rollup-product  = "rollup_product"
    notify-stewards = "notify_stewards"
  }

  function_environment = {
    PROJECT_ID     = var.project_id
    PROJECT_NUMBER = data.google_project.current.number
    LOG_TABLE      = "${var.project_id}.${google_bigquery_table.readiness_log.dataset_id}.${google_bigquery_table.readiness_log.table_id}"
  }
}

resource "google_storage_bucket" "function_source" {
  name                        = "${var.project_id}-function-source"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = { domain = "metadata-feed" }

  depends_on = [time_sleep.api_propagation]
}

data "archive_file" "function" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${path.module}/../functions/${each.value}"
  output_path = "${path.module}/.build/${each.key}.zip"
  excludes    = [".venv", "__pycache__"]
}

resource "google_storage_bucket_object" "function_source" {
  for_each = local.functions

  name   = "${each.key}-${data.archive_file.function[each.key].output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function[each.key].output_path
}

resource "google_service_account" "functions" {
  account_id   = "drift-functions"
  display_name = "Runtime identity for the schema drift functions"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "functions" {
  for_each = toset([
    "roles/dataplex.catalogEditor",      # read entries, write readiness aspects
    "roles/dataplex.aspectTypeUser",     # attach the custom readiness aspect types
    "roles/dataplex.dataProductsViewer", # list data products, their assets and access groups
    "roles/bigquery.jobUser",            # notify-stewards reads its last notification
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.functions.member
}

resource "google_bigquery_dataset_iam_member" "functions_log_writer" {
  dataset_id = google_bigquery_dataset.domains["contract_monitoring"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_service_account.functions.member
}

resource "google_service_account" "function_builder" {
  account_id   = "function-builder"
  display_name = "Cloud Build identity for the function containers"

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_iam_member" "function_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = google_service_account.function_builder.member
}

resource "google_service_account" "push_invoker" {
  account_id   = "feed-push-invoker"
  display_name = "Identity Pub/Sub uses to push feed messages to the functions"

  depends_on = [time_sleep.api_propagation]
}

module "check_contract" {
  source = "./modules/function"

  name                    = "check-contract"
  region                  = var.region
  entry_point             = "check_contract"
  source_bucket           = google_storage_bucket.function_source.name
  source_object           = google_storage_bucket_object.function_source["check-contract"].name
  build_service_account   = google_service_account.function_builder.id
  runtime_service_account = google_service_account.functions.email
  invoker_member          = google_service_account.push_invoker.member
  max_instances           = 5
  environment             = local.function_environment

  depends_on = [
    time_sleep.api_propagation,
    google_project_iam_member.function_builder,
  ]
}

# Deployed after check-contract: the first function in a project creates the
# shared gcf-v2-sources bucket, and two parallel first deploys fail with
# "409 Could not create bucket gcf-v2-sources-<number>-<region>".
module "rollup_product" {
  source = "./modules/function"

  name                    = "rollup-product"
  region                  = var.region
  entry_point             = "rollup_product"
  source_bucket           = google_storage_bucket.function_source.name
  source_object           = google_storage_bucket_object.function_source["rollup-product"].name
  build_service_account   = google_service_account.function_builder.id
  runtime_service_account = google_service_account.functions.email
  invoker_member          = google_service_account.push_invoker.member

  # One instance at a time: each run recomputes the whole product from all of
  # its assets, so serialising runs means the last write is the latest state.
  max_instances = 1
  environment   = local.function_environment

  depends_on = [module.check_contract]
}

module "notify_stewards" {
  source = "./modules/function"

  name                    = "notify-stewards"
  region                  = var.region
  entry_point             = "notify_stewards"
  source_bucket           = google_storage_bucket.function_source.name
  source_object           = google_storage_bucket_object.function_source["notify-stewards"].name
  build_service_account   = google_service_account.function_builder.id
  runtime_service_account = google_service_account.functions.email
  invoker_member          = google_service_account.push_invoker.member

  # One instance at a time, so two deliveries for the same asset cannot both
  # miss each other's entry in the notification log.
  max_instances = 1
  environment = merge(local.function_environment, {
    NOTIFICATION_TOPIC  = google_pubsub_topic.notifications.id
    NOTIFICATION_LOG    = "${var.project_id}.${google_bigquery_table.notification_log.dataset_id}.${google_bigquery_table.notification_log.table_id}"
    NOTIFY_ACCESS_GROUP = var.notify_access_group
  })

  depends_on = [
    module.rollup_product,
    google_pubsub_topic_iam_member.functions_publish_notifications,
  ]
}
