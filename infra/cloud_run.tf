resource "google_cloud_run_v2_service" "producer" {
  name     = "orbitalsense-producer-${var.env}"
  location = var.region

  # Not public. Invoke with an identity token from your own account:
  #   curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" ...
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.producer.email

    scaling {
      min_instance_count = var.producer_min_instances

      # Exactly one producer, by design. Three instances would each simulate
      # the whole constellation, and the deduplication numbers would be
      # meaningless.
      max_instance_count = 1
    }

    containers {
      image = var.producer_image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }

        # CRITICAL. Cloud Run throttles CPU to near zero between requests by
        # default, which stalls the background publishing thread for minutes
        # and looks exactly like a pipeline bug.
        cpu_idle = false
      }

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "TOPIC_ID"
        value = google_pubsub_topic.telemetry.name
      }
      env {
        name  = "SATELLITE_COUNT"
        value = tostring(var.satellite_count)
      }
      env {
        name  = "GROUND_STATIONS"
        value = join(",", var.ground_stations)
      }
      env {
        name  = "SUBSYSTEMS"
        value = join(",", var.subsystems)
      }
      env {
        name  = "PRODUCER_VERSION"
        value = "0.1.0"
      }
      env {
        name  = "EMIT_INTERVAL_S"
        value = tostring(var.emit_interval_seconds)
      }
      env {
        name  = "MALFORMED_RATE"
        value = tostring(var.malformed_rate)
      }
      env {
        name  = "DUPLICATE_RATE"
        value = tostring(var.duplicate_rate)
      }
      env {
        name  = "BLACKOUT_ENABLED"
        value = "true"
      }

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get {
          path = "/healthz"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 6
      }
    }
  }

  depends_on = [google_pubsub_topic_iam_member.producer_publish]
}
