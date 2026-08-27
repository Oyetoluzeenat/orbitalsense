-- Telemetry volume normalised by contact opportunity.
DECLARE window_hours INT64 DEFAULT 6;

WITH events AS (
  SELECT satellite_id, subsystem, ground_station_id, event_time, alert_code
  FROM `PROJECT.orbitalsense_dev.curated_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
),

-- Contact time: a satellite/station pair is "in contact" during any minute
-- in which we received at least one message from it via that station.
contact AS (
  SELECT satellite_id,
         COUNT(DISTINCT FORMAT_TIMESTAMP('%F %H:%M', TIMESTAMP_TRUNC(event_time, MINUTE))
                        || '|' || ground_station_id) AS contact_minutes,
         COUNT(DISTINCT ground_station_id) AS stations_used
  FROM events GROUP BY satellite_id
),

volume AS (
  SELECT satellite_id,
         COUNT(*) AS events,
         COUNTIF(alert_code IS NOT NULL) AS alerting_events,
         MIN(event_time) AS first_seen,
         MAX(event_time) AS last_seen
  FROM events GROUP BY satellite_id
),

quarantined AS (
  SELECT satellite_id, COUNT(*) AS rejected
  FROM `PROJECT.orbitalsense_dev.quarantine_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
    AND satellite_id IS NOT NULL
  GROUP BY satellite_id
)

SELECT
  v.satellite_id,
  v.events,
  IFNULL(q.rejected, 0)                                   AS rejected,
  c.contact_minutes,
  c.stations_used,
  ROUND(v.events / NULLIF(c.contact_minutes, 0), 2)       AS events_per_contact_minute,
  ROUND(100 * v.alerting_events / NULLIF(v.events, 0), 2) AS alert_pct,
  -- Rank raw volume against coverage-normalised volume. A large positive
  -- delta means the satellite only LOOKS chatty because it is well covered.
  RANK() OVER (ORDER BY v.events DESC)                                       AS rank_raw,
  RANK() OVER (ORDER BY v.events / NULLIF(c.contact_minutes, 0) DESC)        AS rank_normalised,
  RANK() OVER (ORDER BY v.events DESC)
    - RANK() OVER (ORDER BY v.events / NULLIF(c.contact_minutes, 0) DESC)    AS coverage_bias
FROM volume v
JOIN contact c USING (satellite_id)
LEFT JOIN quarantined q USING (satellite_id)
ORDER BY v.events DESC;