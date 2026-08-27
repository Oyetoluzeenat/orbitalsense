#!/usr/bin/env bash
#
# Control the producer and drive the fault drills.
#
# Usage:
#   ./scripts/inject_fault.sh start
#   ./scripts/inject_fault.sh stop
#   ./scripts/inject_fault.sh stats
#   ./scripts/inject_fault.sh fault RENAMED_FIELD [COUNT]
#   ./scripts/inject_fault.sh duplicates [COUNT]
#   ./scripts/inject_fault.sh drill1 | drill2 | drill3   direct Pub/Sub publishes
#   ./scripts/inject_fault.sh verify                     reconciliation query
#   ./scripts/inject_fault.sh quarantine                 rejection breakdown
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"

tf() { (cd infra && terraform output -raw "$1"); }

PRODUCER_URL="${PRODUCER_URL:-$(tf producer_url)}"
DATASET="${DATASET:-$(tf dataset)}"
TOPIC="${TOPIC:-$(tf topic_name)}"

call() {
  local method="$1" path="$2"
  curl -sS -X "${method}" "${PRODUCER_URL}${path}" \
    -H "Authorization: Bearer $(gcloud auth print-identity-token)"
  echo
}

publish() {
  local body="$1" attrs="$2"
  gcloud pubsub topics publish "${TOPIC}" --message="${body}" --attribute="${attrs}"
}

bq_query() {
  bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=prettyjson "$1"
}

FAULT_MODES="MALFORMED_JSON WRONG_TYPE IMPOSSIBLE_VALUE RENAMED_FIELD MISSING_FIELD FUTURE_TIMESTAMP NEGATIVE_SEQUENCE"

case "${1:-help}" in
  start)  call POST /start ;;
  stop)   call POST /stop ;;
  stats)  call GET  /stats ;;

  fault)
    MODE="${2:?mode required. One of: ${FAULT_MODES}}"
    COUNT="${3:-1}"
    call POST "/inject/${MODE}?count=${COUNT}"
    ;;

  duplicates)
    call POST "/inject/duplicates?count=${2:-100}"
    ;;

  # Drill 1 — valid JSON, physically impossible value.
  # Expect: OUT_OF_BOUNDS, offending_field=battery_voltage_v. Target < 60s.
  drill1)
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    publish "{\"event_id\":\"drill-1\",\"satellite_id\":\"SAT-01\",\"subsystem\":\"power\",\"sequence\":1,\"event_time\":\"${TS}\",\"metrics\":{\"battery_voltage_v\":9999.0}}" \
            "ground_station_id=GS-1,event_id=drill-1"
    echo "published drill-1; expect reason_code=OUT_OF_BOUNDS"
    ;;

  # Drill 2 — silently renamed field. The one to over-rehearse: it lets you
  # tell the whole story about why comms shows zero alerts.
  drill2)
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    publish "{\"event_id\":\"drill-2\",\"satellite_id\":\"SAT-02\",\"subsystem\":\"comms\",\"sequence\":1,\"event_time\":\"${TS}\",\"metrics\":{\"signalStrength\":-95.0}}" \
            "ground_station_id=GS-2,event_id=drill-2"
    echo "published drill-2; expect reason_code=SCHEMA_DRIFT"
    ;;

  # Drill 3 — duplicate burst straight at the topic, bypassing the producer.
  drill3)
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    BODY="{\"event_id\":\"drill-3\",\"satellite_id\":\"SAT-03\",\"subsystem\":\"power\",\"sequence\":1,\"event_time\":\"${TS}\",\"metrics\":{\"battery_voltage_v\":27.5}}"
    for _ in $(seq 1 "${2:-50}"); do
      publish "${BODY}" "ground_station_id=GS-3,event_id=drill-3"
    done
    echo "published drill-3 burst; expect exactly one curated row"
    ;;

  verify)
    bq_query "
      SELECT
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.raw_telemetry\`
          WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)) AS raw,
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.curated_telemetry\`
          WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)) AS curated,
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.quarantine_telemetry\`
          WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)) AS quarantined"
    echo "raw = curated + quarantined + duplicates suppressed. Account for the difference."
    ;;

  quarantine)
    bq_query "
      SELECT reason_code, offending_field, ground_station_id, COUNT(*) AS n,
             ANY_VALUE(reason_detail) AS example
      FROM \`${PROJECT_ID}.${DATASET}.quarantine_telemetry\`
      WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
      GROUP BY reason_code, offending_field, ground_station_id
      ORDER BY n DESC LIMIT 25"
    ;;

  *)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
esac
