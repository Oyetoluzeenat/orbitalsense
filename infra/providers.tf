terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # A backend block cannot use variables, so the bucket is supplied at init:
  #   terraform init \
  #     -backend-config="bucket=${PROJECT_ID}-tfstate" \
  #     -backend-config="prefix=orbitalsense/dev"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}
