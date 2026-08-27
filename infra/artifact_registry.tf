resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "orbitalsense"
  description   = "OrbitalSense container images"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  depends_on = [time_sleep.api_propagation]
}
