# =============================================================================
# ENABLED APIS
# Only the services the metadata-feed domain actually uses.
# =============================================================================

resource "google_project_service" "apis" {
  for_each = toset([
    # Bootstrap pair — also pre-enabled imperatively by infra/scripts/setup.sh, since
    # the provider needs CRM before it can manage any service. Declared here too
    # so the set is complete and self-documenting.
    "cloudresourcemanager.googleapis.com", # provider manages google_project_service via CRM
    "serviceusage.googleapis.com",         # enable/disable of the services below

    "bigquery.googleapis.com",         # source copies, golden tables, view, readiness log
    "dataplex.googleapis.com",         # Knowledge Catalog: aspects, data product, metadata feeds
    "pubsub.googleapis.com",           # feed topics, push and demo subscriptions
    "cloudfunctions.googleapis.com",   # check-contract, rollup-product, notify-stewards
    "run.googleapis.com",              # Cloud Functions Gen2 run on Cloud Run
    "cloudbuild.googleapis.com",       # builds the function containers
    "artifactregistry.googleapis.com", # stores the function containers
    "storage.googleapis.com",          # function source bucket
    "iam.googleapis.com",              # function and invoker service accounts
    "cloudaicompanion.googleapis.com", # Gemini for Google Cloud, used by the insights scans
  ])

  service = each.value

  # Disabling a service on teardown can break unrelated things in a project
  # that outlives this domain.
  disable_on_destroy = false
}
