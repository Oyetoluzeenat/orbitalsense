-- Proves duplicates are absorbed: raw records every delivery, curated records
-- the event once. Run after publishing N identical copies of one event_id.
--
-- Measured on this system:
--   pipeline_version 1.0.0-dev   (no dedup):  21 duplicated on wire -> 42 curated rows
--   pipeline_version 1.1.0-dedup (dedup on):  20 identical copies   ->  1 curated row
SELECT
  (SELECT COUNT(*) FROM `PROJECT.DATASET.raw_telemetry`
    WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE)
      AND JSON_VALUE(payload, '$.event_id') = @event_id) AS in_raw,
  (SELECT COUNT(*) FROM `PROJECT.DATASET.curated_telemetry`
    WHERE event_id = @event_id) AS in_curated;
