# =============================================================================
# OUTPUTS
# Blocks carrying an [addon:*] tag belong to the GCS + BigLake + Gemini add-on —
# delete them if the add-on is removed, or `tofu validate` fails on the missing
# resources. (Wildcard, so init.sh doesn't strip this line as a tag itself.)
# =============================================================================

output "project_id" {
  description = "The GCP project ID"
  value       = var.project_id
}

# Delete alongside the `raw` entry in datasets.tf if the domain lands no raw data.
output "raw_dataset_id" {
  description = "The raw-stage BigQuery dataset ID"
  value       = google_bigquery_dataset.stages["raw"].dataset_id
}

output "processed_dataset_id" {
  description = "The processed-stage BigQuery dataset ID"
  value       = google_bigquery_dataset.stages["processed"].dataset_id
}

output "serving_dataset_id" {
  description = "The serving-stage BigQuery dataset ID"
  value       = google_bigquery_dataset.stages["serving"].dataset_id
}

output "assertions_dataset_id" {
  description = "The dataset holding data-quality assertions and monitoring views"
  value       = google_bigquery_dataset.stages["assertions"].dataset_id
}

output "dataform_repository_name" {
  description = "The Dataform repository name"
  value       = local.dataform_repository_name
}

output "dataform_release_config_name" {
  description = "The Dataform release configuration name (null unless enable_scheduled_runs)"
  value       = one(google_dataform_repository_release_config.main[*].name)
}

output "dataform_workflow_config_name" {
  description = "The Dataform workflow configuration name (null unless enable_scheduled_runs)"
  value       = one(google_dataform_repository_workflow_config.main[*].name)
}


