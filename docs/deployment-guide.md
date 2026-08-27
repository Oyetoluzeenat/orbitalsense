terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
  backend "gcs" {
    # values supplied via -backend-config; a backend block cannot use variables
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
cd infra
terraform init \
  -backend-config="bucket=${PROJECT_ID}-tfstate" \
  -backend-config="prefix=orbitalsense/dev"