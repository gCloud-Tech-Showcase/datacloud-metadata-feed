# =============================================================================
# SCHEMA CHANGE NOTIFICATIONS
# notify-stewards publishes one message here per data product whenever the set
# of differences between an asset and its contract changes. The message names
# the Google Group of the data product's notify access group as the recipient.
# An email sender would be one more subscriber on this topic.
# =============================================================================

resource "google_pubsub_topic" "notifications" {
  name   = "schema-change-notifications"
  labels = { domain = "metadata-feed" }

  depends_on = [google_project_service.apis["pubsub.googleapis.com"]]
}

resource "google_pubsub_subscription" "notifications_demo" {
  name  = "schema-change-notifications-demo"
  topic = google_pubsub_topic.notifications.id

  # Acked messages stay seekable for a day, so you can replay them.
  retain_acked_messages      = true
  message_retention_duration = "86400s"
  ack_deadline_seconds       = 10

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "functions_publish_notifications" {
  topic  = google_pubsub_topic.notifications.name
  role   = "roles/pubsub.publisher"
  member = google_service_account.functions.member
}

resource "google_bigquery_table" "notification_log" {
  dataset_id          = google_bigquery_dataset.domains["contract_monitoring"].dataset_id
  table_id            = "notification_log"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "notified_at"
  }

  schema = jsonencode([
    { name = "notified_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "data_product", type = "STRING", mode = "REQUIRED" },
    { name = "asset", type = "STRING", mode = "REQUIRED", description = "dataset.table" },
    { name = "severity", type = "STRING", mode = "REQUIRED", description = "BREAKING, REVIEW or RESOLVED" },
    { name = "status", type = "STRING", mode = "REQUIRED", description = "Asset readiness when notified" },
    { name = "recipient", type = "STRING", mode = "NULLABLE", description = "Google Group of the notify access group, if any" },
    { name = "new_reasons", type = "JSON", mode = "NULLABLE" },
    { name = "all_reasons", type = "JSON", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "REQUIRED", description = "Pub/Sub message ID on schema-change-notifications" },
  ])
}
