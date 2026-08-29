# ---------------------------------------------------------------------------
# Producer identity
# ---------------------------------------------------------------------------

resource "google_service_account" "producer" {
  account_id   = "orbitalsense-producer-${var.env}"
  display_name = "OrbitalSense telemetry producer"
  depends_on   = [time_sleep.api_propagation]
}

# Resource-scoped: it can publish to THIS topic and nothing else.
resource "google_pubsub_topic_iam_member" "producer_publish" {
  topic  = google_pubsub_topic.telemetry.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.producer.email}"
}

# ---------------------------------------------------------------------------
# Dataflow identity
# ---------------------------------------------------------------------------

resource "google_service_account" "dataflow" {
  account_id   = "orbitalsense-dataflow-${var.env}"
  display_name = "OrbitalSense streaming pipeline"
  depends_on   = [time_sleep.api_propagation]
}

# Project-scoped because dataflow.worker has no resource-scoped form.
resource "google_project_iam_member" "dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_subscription_iam_member" "dataflow_subscribe" {
  subscription = google_pubsub_subscription.pipeline.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_topic_iam_member" "dataflow_dlq_publish" {
  topic  = google_pubsub_topic.delivery_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_bigquery_dataset_iam_member" "dataflow_bq" {
  dataset_id = google_bigquery_dataset.telemetry.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dataflow.email}"
}

# Project-scoped because jobUser has no dataset-scoped equivalent.
resource "google_project_iam_member" "dataflow_bq_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_storage_bucket_iam_member" "dataflow_temp" {
  bucket = google_storage_bucket.dataflow_temp.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

# Launching a job AS this service account requires impersonation rights.
# Doing this by hand and forgetting it is a classic destroy/apply failure.
resource "google_service_account_iam_member" "dataflow_impersonation" {
  service_account_id = google_service_account.dataflow.name
  role               = "roles/iam.serviceAccountUser"
  member             = "user:${var.deployer_account}"
}

# ---------------------------------------------------------------------------
# Pub/Sub service agent
#
# Without these two bindings, dead-lettering appears configured and simply
# never happens. Classic silent failure; add them on day one, not day seven.
# ---------------------------------------------------------------------------

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "agent_publish_dlq" {
  topic  = google_pubsub_topic.delivery_dlq.name
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "agent_ack" {
  subscription = google_pubsub_subscription.pipeline.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# Dataflow needs pubsub.subscriptions.get for backlog reporting and Streaming
# Engine bookkeeping. subscriber alone permits pulling but not describing, which
# surfaces as GETTING_PUBSUB_SUBSCRIPTION_FAILED in the job log.
resource "google_project_iam_member" "dataflow_pubsub_viewer" {
  project = var.project_id
  role    = "roles/pubsub.viewer"
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}
