# =============================================================================
# METADATA CHANGE FEEDS
#
#   schema-changes     feed: schema or schema-contract changed on any entry
#                      -> push to check-contract
#   readiness-changes  feed: asset-readiness changed on any entry
#                      -> push to rollup-product and to notify-stewards
#
# Each topic also has a `-demo` pull subscription that nothing consumes, so you
# can pull and ack messages without starving the functions.
# =============================================================================

locals {
  # Feed filters only matched when system types used the project-number form.
  # A feed filtered on `projects/dataplex-types/...` was accepted by the API
  # but never delivered a message.
  dataplex_types = "projects/655216118709/locations/global"

  aspect_type_prefix = "projects/${data.google_project.current.number}/locations/${var.region}/aspectTypes"

  feeds = {
    schema-changes = {
      description = "Schema or schema contract changed on a catalog entry"
      aspect_types = [
        "${local.dataplex_types}/aspectTypes/schema",
        "${local.aspect_type_prefix}/${google_dataplex_aspect_type.schema_contract.aspect_type_id}",
      ]
    }

    readiness-changes = {
      description  = "Asset readiness changed on a catalog entry"
      aspect_types = ["${local.aspect_type_prefix}/${google_dataplex_aspect_type.asset_readiness.aspect_type_id}"]
    }
  }

  push_subscriptions = {
    schema-changes-push      = { topic = "schema-changes", endpoint = module.check_contract.uri }
    readiness-changes-push   = { topic = "readiness-changes", endpoint = module.rollup_product.uri }
    readiness-changes-notify = { topic = "readiness-changes", endpoint = module.notify_stewards.uri }
  }
}

resource "google_pubsub_topic" "feed" {
  for_each = local.feeds

  name   = each.key
  labels = { domain = "metadata-feed" }

  depends_on = [time_sleep.api_propagation]
}

resource "google_project_service_identity" "dataplex" {
  provider = google-beta
  service  = "dataplex.googleapis.com"

  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_topic_iam_member" "dataplex_publisher" {
  for_each = {
    for pair in setproduct(keys(local.feeds), ["roles/pubsub.publisher", "roles/pubsub.viewer"]) :
    "${pair[0]}/${pair[1]}" => { topic = pair[0], role = pair[1] }
  }

  topic  = google_pubsub_topic.feed[each.value.topic].name
  role   = each.value.role
  member = google_project_service_identity.dataplex.member
}

# Creating a feed before the service agent's publisher grant propagates fails
# with an unhelpful `code 13: an internal error has occurred`.
resource "time_sleep" "dataplex_publisher_propagation" {
  create_duration = "90s"

  depends_on = [google_pubsub_topic_iam_member.dataplex_publisher]
}

resource "google_dataplex_metadata_feed" "feed" {
  for_each = local.feeds

  location         = var.region
  metadata_feed_id = each.key
  pubsub_topic     = google_pubsub_topic.feed[each.key].id

  scope {
    projects = ["projects/${data.google_project.current.number}"]
  }

  filters {
    aspect_types = each.value.aspect_types
  }

  labels = { domain = "metadata-feed" }

  depends_on = [time_sleep.dataplex_publisher_propagation]
}

resource "google_pubsub_subscription" "demo" {
  for_each = local.feeds

  name  = "${each.key}-demo"
  topic = google_pubsub_topic.feed[each.key].id

  # Acked messages stay seekable for a day, so you can replay them.
  retain_acked_messages      = true
  message_retention_duration = "86400s"
  ack_deadline_seconds       = 10

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic" "dead_letter" {
  name   = "feed-dead-letter"
  labels = { domain = "metadata-feed" }

  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_subscription" "dead_letter" {
  name                       = "feed-dead-letter-pull"
  topic                      = google_pubsub_topic.dead_letter.id
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "push" {
  for_each = local.push_subscriptions

  name                 = each.key
  topic                = google_pubsub_topic.feed[each.value.topic].id
  ack_deadline_seconds = 60

  push_config {
    push_endpoint = each.value.endpoint

    oidc_token {
      service_account_email = google_service_account.push_invoker.email
    }
  }

  # Push subscriptions rather than Eventarc triggers, so a failing function's
  # messages land in a dead-letter topic instead of being lost.
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [
    google_pubsub_topic_iam_member.pubsub_dead_letter_publisher,
    module.check_contract,
    module.rollup_product,
    module.notify_stewards,
  ]
}

# Pub/Sub's own service agent forwards undeliverable messages, so it needs to
# publish to the dead-letter topic and to ack on the source subscription.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  service  = "pubsub.googleapis.com"

  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_topic_iam_member" "pubsub_dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription_iam_member" "pubsub_dead_letter_subscriber" {
  for_each = local.push_subscriptions

  subscription = google_pubsub_subscription.push[each.key].name
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub.member
}

# The docs allow up to 10 minutes for a new feed to start publishing. Contracts
# are attached after this wait so their first evaluation is not lost.
resource "time_sleep" "feed_activation" {
  create_duration = "10m"

  depends_on = [
    google_dataplex_metadata_feed.feed,
    google_pubsub_subscription.push,
  ]
}
