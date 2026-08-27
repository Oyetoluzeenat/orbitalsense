DECLARE window_hours INT64 DEFAULT 6;

WITH curated AS (
  SELECT subsystem,
         COUNT(*)                                     AS events_accepted,
         COUNTIF(alert_code IS NOT NULL)              AS alerts,
         COUNTIF(alert_severity = 'CRITICAL')         AS critical_alerts,
         COUNT(DISTINCT satellite_id)                 AS satellites_reporting
  FROM `PROJECT.orbitalsense_dev.curated_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
  GROUP BY subsystem
),

quarantine AS (
  SELECT subsystem,
         COUNT(*) AS events_rejected,
         COUNT(DISTINCT reason_code) AS distinct_reasons,
         -- The most common rejection reason for this subsystem
         ARRAY_AGG(reason_code ORDER BY reason_code LIMIT 1)[OFFSET(0)] AS a_reason,
         STRING_AGG(DISTINCT offending_field ORDER BY offending_field LIMIT 5) AS fields
  FROM `PROJECT.orbitalsense_dev.quarantine_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
    AND subsystem IS NOT NULL
  GROUP BY subsystem
)

SELECT
  COALESCE(c.subsystem, q.subsystem) AS subsystem,
  IFNULL(c.events_accepted, 0)       AS accepted,
  IFNULL(c.alerts, 0)                AS alerts,
  IFNULL(c.critical_alerts, 0)       AS critical,
  IFNULL(q.events_rejected, 0)       AS rejected,
  ROUND(100 * IFNULL(q.events_rejected, 0)
        / NULLIF(IFNULL(c.events_accepted,0) + IFNULL(q.events_rejected,0), 0), 2)
                                     AS rejection_rate_pct,
  q.a_reason                         AS top_reason_code,
  q.fields                           AS offending_fields,
  CASE
    WHEN IFNULL(q.events_rejected,0) = 0 THEN 'CLEAN'
    WHEN IFNULL(q.events_rejected,0)
         > IFNULL(c.events_accepted,0) * 0.10 THEN 'ALERT_COUNT_UNRELIABLE'
    ELSE 'MINOR_LOSS'
  END AS data_quality_verdict
FROM curated c
FULL OUTER JOIN quarantine q ON c.subsystem = q.subsystem
ORDER BY alerts DESC;
-- Diagnostic drill-down: where is the rot, and is it one ground station?
SELECT reason_code, offending_field, ground_station_id,
       COUNT(*) AS n,
       MIN(ingest_time) AS first_seen,
       MAX(ingest_time) AS last_seen,
       ANY_VALUE(reason_detail) AS example_detail,
       ANY_VALUE(SUBSTR(raw_payload, 1, 220)) AS example_payload
FROM `PROJECT.orbitalsense_dev.quarantine_telemetry`
WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
GROUP BY reason_code, offending_field, ground_station_id
ORDER BY n DESC
LIMIT 25;