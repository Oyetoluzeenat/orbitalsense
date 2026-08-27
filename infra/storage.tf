resource "google_storage_bucket" "dataflow_temp" {
  name                        = "${var.project_id}-dataflow-temp"
  location                    = var.region
  uniform_bucket_level_access = true

  # A bucket containing objects blocks terraform destroy. Working buckets must
  # be destroyable or the reproducibility check fails.
  force_destroy = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_storage_bucket" "raw_archive" {
  name                        = "${var.project_id}-raw-archive"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  # This is the retention policy from the design rationale, expressed in code
  # rather than in a document nobody reads.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = var.raw_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [time_sleep.api_propagation]
}
