output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "topic" {
  value       = google_pubsub_topic.telemetry.id
  description = "Fully qualified telemetry topic."
}

output "topic_name" {
  value = google_pubsub_topic.telemetry.name
}

output "subscription" {
  value       = google_pubsub_subscription.pipeline.id
  description = "Fully qualified subscription, consumed by the Beam pipeline."
}

output "subscription_name" {
  value = google_pubsub_subscription.pipeline.name
}

output "dlq_topic_name" {
  value = google_pubsub_topic.delivery_dlq.name
}

output "dataset" {
  value = google_bigquery_dataset.telemetry.dataset_id
}

output "dataflow_sa" {
  value = google_service_account.dataflow.email
}

output "producer_sa" {
  value = google_service_account.producer.email
}

output "producer_url" {
  value = google_cloud_run_v2_service.producer.uri
}

output "temp_bucket" {
  value = google_storage_bucket.dataflow_temp.name
}

output "artifact_repo" {
  value = google_artifact_registry_repository.images.repository_id
}

output "allowed_lateness_minutes" {
  value = var.allowed_lateness_minutes
}

output "dedup_window_minutes" {
  value = var.dedup_window_minutes
}

output "pipeline_version" {
  value = var.pipeline_version
}
