-- Locate a specific injected fault. Substitute the event_id.
-- Used during live fault-response drills: publish, then find it in under 60s.
SELECT reason_code, offending_field, offending_value, reason_detail,
       ground_station_id, ingest_time
FROM `PROJECT.DATASET.quarantine_telemetry`
WHERE event_id = 'drill-1';
