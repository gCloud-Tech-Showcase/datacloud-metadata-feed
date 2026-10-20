# =============================================================================
# ENABLED APIS
# Only the services the __DOMAIN_SLUG__ domain actually uses. Lines carrying an
# [addon:*] tag belong to the GCS + BigLake + Gemini add-on — they go along with
# storage.tf / seed.tf / scripts/ / data/ if it's unused. Lines carrying a
# [visibility:*] tag belong to one of the two Dataform git-link paths; init.sh
# keeps whichever matches the repo. (Wildcards, so init.sh doesn't strip these
# lines as tags in their own right.)
# =============================================================================

resource "google_project_service" "apis" {
  for_each = toset([
    # Bootstrap pair — also pre-enabled imperatively by scripts/setup.sh, since
    # the provider needs CRM before it can manage any service. Declared here too
    # so the set is complete and self-documenting.
    "cloudresourcemanager.googleapis.com", # provider manages google_project_service via CRM
    "serviceusage.googleapis.com",         # enable/disable of the services below

    "bigquery.googleapis.com",       # queries, tables, models
    "dataform.googleapis.com",       # managed git-linked Dataform repository
    "iam.googleapis.com",            # execution service account
    "iamcredentials.googleapis.com", # service-account impersonation (Dataform act-as runner)
    "datalineage.googleapis.com",    # automatic BigQuery/Dataform data lineage capture

    # Needed for BQML models registered in Vertex (model_registry='vertex_ai'),
    # and for any Gemini call from BigQuery. Keep unless the domain is pure SQL.
    "aiplatform.googleapis.com",

    "secretmanager.googleapis.com", # [visibility:private] holds Dataform's SSH deploy key

    "bigqueryconnection.googleapis.com", # [addon:unstructured] BQ -> Vertex/GCS connection
    "storage.googleapis.com",            # [addon:unstructured] bucket backing the object table
  ])

  service = each.value

  # Disabling a service on teardown can break unrelated things in a project
  # that outlives this domain.
  disable_on_destroy = false
}
