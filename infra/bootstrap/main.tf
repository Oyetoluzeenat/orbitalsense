# Bootstrap: creates the bucket that holds Terraform state for the main module.
#
# This is a separate root module because a backend cannot create the bucket it
# stores its own state in. Its own state stays local and is not committed; it
# manages exactly one resource and is run once per project.

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "GCP project that will hold the state bucket."
}

variable "region" {
  type        = string
  description = "Region for the state bucket. Must match the main module."
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true

  # Deliberately NOT force_destroy: working buckets should be destroyable,
  # the state bucket should not be.
  force_destroy = false

  # Object versioning is the only thing between a corrupted state file and
  # reconciling forty resources by hand.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }
}

output "bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "Pass this to: terraform init -backend-config=\"bucket=<this>\""
}
