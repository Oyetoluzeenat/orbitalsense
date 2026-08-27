#!/usr/bin/env bash
set -euo pipefail
: "${PROJECT_ID:?}" "${REGION:?}"
TAG="${1:-0.1.0}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/orbitalsense/producer:${TAG}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker build --platform linux/amd64 -t "$IMAGE" producer/
docker push "$IMAGE"

cd infra
terraform apply -var-file=envs/dev.tfvars -var="producer_image=${IMAGE}" -auto-approve