locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "dataflow.googleapis.com",
    "compute.googleapis.com", # Dataflow workers are GCE VMs
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Disabling an API on destroy can break unrelated things in the project and
  # makes destroy slow and flaky. Destroy should remove OUR resources, cleanly.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# API enablement is eventually consistent. Without this wait, a fresh apply
# regularly fails on the first resource that touches a just-enabled API — which
# is the number one cause of "it worked the second time" during a live review.
resource "time_sleep" "api_propagation" {
  depends_on      = [google_project_service.enabled]
  create_duration = "60s"
}
