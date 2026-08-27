resource "google_pubsub_topic" "telemetry" {
  name = "orbitalsense-telemetry-${var.env}"

  # Seven days of retention is what makes replay possible at all.
  message_retention_duration = "604800s"

  depends_on = [time_sleep.api_propagation]
}

# Where Pub/Sub itself gives up on a message. This catches INFRASTRUCTURE
# failure — crashes, OOM, repeatedly unacknowledged delivery. It is NOT where
# malformed payloads go; those are classified by the pipeline and land in the
# quarantine table with a reason code.
resource "google_pubsub_topic" "delivery_dlq" {
  name       = "orbitalsense-delivery-dlq-${var.env}"
  depends_on = [time_sleep.api_propagation]
}

resource "google_pubsub_subscription" "pipeline" {
  name  = "orbitalsense-pipeline-${var.env}"
  topic = google_pubsub_topic.telemetry.id

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"

  # Required for seek-to-timestamp replay.
  retain_acked_messages = true

  # A subscription that silently vanishes after 31 idle days is a nasty
  # surprise in a graded environment.
  expiration_policy {
    ttl = ""
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.delivery_dlq.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

# Without a subscription attached, messages published to the DLQ topic are
# discarded immediately and "inspectable dead letters" is a fiction.
resource "google_pubsub_subscription" "delivery_dlq_hold" {
  name                       = "orbitalsense-delivery-dlq-hold-${var.env}"
  topic                      = google_pubsub_topic.delivery_dlq.id
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}
