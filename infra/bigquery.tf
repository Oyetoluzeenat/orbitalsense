resource "google_bigquery_dataset" "telemetry" {
  dataset_id                 = "orbitalsense_${var.env}"
  location                   = var.region
  delete_contents_on_destroy = true
  depends_on                 = [time_sleep.api_propagation]

  labels = { env = var.env, system = "orbitalsense" }
}

resource "google_bigquery_table" "raw_telemetry" {
  dataset_id               = google_bigquery_dataset.telemetry.dataset_id
  table_id                 = "raw_telemetry"
  deletion_protection      = false
  schema                   = file("${path.module}/schemas/raw_telemetry.json")
  require_partition_filter = true

  time_partitioning {
    type          = "DAY"
    field         = "ingest_time"
    expiration_ms = var.raw_retention_days * 86400000
  }
  clustering = ["ground_station_id"]
}

resource "google_bigquery_table" "curated_telemetry" {
  dataset_id               = google_bigquery_dataset.telemetry.dataset_id
  table_id                 = "curated_telemetry"
  deletion_protection      = false
  schema                   = file("${path.module}/schemas/curated_telemetry.json")
  require_partition_filter = false

  time_partitioning {
    type          = "DAY"
    field         = "ingest_time"
    expiration_ms = var.curated_retention_days * 86400000
  }
  clustering = ["satellite_id", "subsystem"]
}

resource "google_bigquery_table" "quarantine_telemetry" {
  dataset_id          = google_bigquery_dataset.telemetry.dataset_id
  table_id            = "quarantine_telemetry"
  deletion_protection = false
  schema              = file("${path.module}/schemas/quarantine_telemetry.json")

  time_partitioning {
    type          = "DAY"
    field         = "ingest_time"
    expiration_ms = var.quarantine_retention_days * 86400000
  }
  clustering = ["reason_code", "ground_station_id"]
}