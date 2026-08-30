#!/usr/bin/env bash
#
# Launch, drain or cancel the streaming Beam pipeline on Dataflow.
#
# Usage:
#   ./scripts/launch_pipeline.sh              launch on Dataflow
#   ./scripts/launch_pipeline.sh --local      run on the DirectRunner
#   ./scripts/launch_pipeline.sh --drain      graceful stop: in-flight work commits
#   ./scripts/launch_pipeline.sh --cancel     immediate stop: in-flight state discarded
#   ./scripts/launch_pipeline.sh --status     list active jobs
#
# Drain for planned teardown and version upgrades. Cancel when the job is
# already broken and is being replaced anyway. Because Pub/Sub retains
# unacknowledged messages, cancel-and-relaunch reprocesses the backlog rather
# than losing it — which is exactly why deduplication on a stable key matters.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"

ACTION="${1:-launch}"

tf() { (cd infra && terraform output -raw "$1"); }

active_jobs() {
  gcloud dataflow jobs list \
    --region="${REGION}" \
    --status=active \
    --filter='name~orbitalsense' \
    --format='value(id)'
}

case "${ACTION}" in
  --status)
    gcloud dataflow jobs list --region="${REGION}" --status=active \
      --format='table(id,name,state,creationTime)'
    exit 0
    ;;

  --drain|--cancel)
    VERB="${ACTION#--}"
    FOUND=0
    while read -r JOB; do
      [[ -z "${JOB}" ]] && continue
      FOUND=1
      echo "==> ${VERB} ${JOB}"
      gcloud dataflow jobs "${VERB}" "${JOB}" --region="${REGION}"
    done < <(active_jobs)
    if [[ "${FOUND}" -eq 0 ]]; then
      echo "No active OrbitalSense jobs."
    elif [[ "${VERB}" == "drain" ]]; then
      echo "Wait for JOB_STATE_DRAINED before destroying infrastructure,"
      echo "or terraform destroy will hang on the subscription."
    fi
    exit 0
    ;;
esac

SUBSCRIPTION="$(tf subscription)"
DATASET="$(tf dataset)"
SA="$(tf dataflow_sa)"
BUCKET="$(tf temp_bucket)"
LATENESS="$(tf allowed_lateness_minutes)"
DEDUP="$(tf dedup_window_minutes)"
VERSION="${PIPELINE_VERSION:-$(tf pipeline_version)}"

COMMON=(
  pipeline/main.py
  --project="${PROJECT_ID}"
  --subscription="${SUBSCRIPTION}"
  --dataset="${DATASET}"
  --pipeline_version="${VERSION}"
  --allowed_lateness_minutes="${LATENESS}"
  --dedup_window_minutes="${DEDUP}"
)

if [[ "${ACTION}" == "--local" ]]; then
  echo "==> DirectRunner. Costs nothing but the Pub/Sub messages."
  exec python "${COMMON[@]}" --runner=DirectRunner --streaming
fi

echo "==> DataflowRunner in ${REGION}"
echo "    Cancel this job when you stop working. It bills until you do."

exec "${PYTHON:-python3}" "${COMMON[@]}" \
  --runner=DataflowRunner \
  --region="${REGION}" \
  --service_account_email="${SA}" \
  --temp_location="gs://${BUCKET}/temp" \
  --staging_location="gs://${BUCKET}/staging" \
  --setup_file=./pipeline/setup.py \
  --job_name="orbitalsense-$(date +%Y%m%d-%H%M%S)" \
  --num_workers=1 \
  --max_num_workers=2 \
  --worker_machine_type=e2-standard-2 \
  --enable_streaming_engine \
  --streaming
