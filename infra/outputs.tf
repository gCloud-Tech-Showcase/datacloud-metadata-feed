# =============================================================================
# OUTPUTS
# =============================================================================

output "project_id" {
  description = "The GCP project ID"
  value       = var.project_id
}

output "data_product" {
  description = "The data product whose assets carry schema contracts"
  value       = google_dataplex_data_product.sales_orders.name
}

output "demo_subscriptions" {
  description = "Pull subscriptions for reading feed messages yourself. Nothing else consumes them."
  value       = { for k, s in google_pubsub_subscription.demo : k => s.name }
}

output "dead_letter_subscription" {
  description = "Messages the functions failed to process after 5 attempts"
  value       = google_pubsub_subscription.dead_letter.name
}
