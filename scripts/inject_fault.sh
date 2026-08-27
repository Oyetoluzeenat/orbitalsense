#!/usr/bin/env bash
#
# Control the producer and drive the fault drills.
#
# Usage:
#   ./scripts/inject_fault.sh start | stop | stats
#   ./scripts/inject_fault.sh drill1        impossible value      -> OUT_OF_BOUNDS
#   ./scripts/inject_fault.sh drill2        renamed field         -> SCHEMA_DRIFT
#   ./scripts/inject_fault.sh drill3 [N]    duplicate burst       -> N in raw, 1 in curated
#   ./scripts/inject_fault.sh verify        reconciliation counts
#   ./scripts/inject_fault.sh quarantine    rejection breakdown
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${PROJECT_ID:?PROJECT_ID must be set}"

tf() { (cd infra && terraform output -raw "$1"); }

URL="${PRODUCER_URL:-$(tf producer_url)}"
TOPIC="${TOPIC:-$(tf topic_name)}"
DATASET="${DATASET:-$(tf dataset)}"

call() {
  curl -sS -X "$1" "${URL}$2" \
    -H "Authorization: Bearer $(gcloud auth print-identity-token)"
  echo
}

publish() {
  gcloud pubsub topics publish "$TOPIC" --message="$1" --attribute="$2" >/dev/null
}

bqq() { bq query --use_legacy_sql=false --format=prettyjson "$1"; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "${1:-help}" in
  start) call POST /start ;;
  stop)  call POST /stop ;;
  stats) call GET  /stats ;;

  # Valid JSON, physically impossible value. Expect OUT_OF_BOUNDS.
  drill1)
    publish "{\"event_id\":\"drill-1\",\"satellite_id\":\"SAT-01\",\"subsystem\":\"power\",\"sequence\":1,\"event_time\":\"$TS\",\"metrics\":{\"battery_voltage_v\":9999.0}}" \
            "ground_station_id=GS-1,event_id=drill-1"
    echo "published drill-1; expect reason_code=OUT_OF_BOUNDS"
    ;;

  # Silently renamed field. Expect SCHEMA_DRIFT — the one that hides comms alerts.
  drill2)
    publish "{\"event_id\":\"drill-2\",\"satellite_id\":\"SAT-02\",\"subsystem\":\"comms\",\"sequence\":1,\"event_time\":\"$TS\",\"metrics\":{\"signalStrength\":-95.0}}" \
            "ground_station_id=GS-2,event_id=drill-2"
    echo "published drill-2; expect reason_code=SCHEMA_DRIFT"
    ;;

  # Duplicate burst: same bytes, same event_id, N times.
  drill3)
    N="${2:-20}"
    ID="dedup-proof-$(date +%s)"
    BODY="{\"event_id\":\"$ID\",\"satellite_id\":\"SAT-05\",\"subsystem\":\"power\",\"sequence\":1,\"event_time\":\"$TS\",\"metrics\":{\"battery_voltage_v\":27.5}}"
    for _ in $(seq 1 "$N"); do
      publish "$BODY" "ground_station_id=GS-2,event_id=$ID,satellite_id=SAT-05"
    done
    echo "published $N identical copies of $ID"
    echo "expect: $N in raw, 1 in curated"
    ;;

  verify)
    bqq "
      SELECT
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.raw_telemetry\`
          WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)) AS raw,
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.curated_telemetry\`) AS curated,
        (SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET}.quarantine_telemetry\`) AS quarantined"
    ;;

  quarantine)
    bqq "
      SELECT reason_code, offending_field, COUNT(*) AS n,
             ANY_VALUE(reason_detail) AS example
      FROM \`${PROJECT_ID}.${DATASET}.quarantine_telemetry\`
      GROUP BY reason_code, offending_field ORDER BY n DESC LIMIT 25"
    ;;

  *) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
