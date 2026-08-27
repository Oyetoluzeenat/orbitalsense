-- WORKING DEFINITION (pending client confirmation, see docs/discovery-answers.md):
--   "Weakest" = lowest MEAN signal_strength_dbm over a contiguous run of
--   hourly buckets, requiring >= 20 samples per bucket. Mean rather than
--   minimum, because a single deep fade during handover is not a weak link;
--   a sustained low mean is. Sample floor prevents a satellite with three
--   readings from winning on noise.
DECLARE window_hours INT64 DEFAULT 12;
DECLARE min_samples INT64 DEFAULT 20;
DECLARE weak_threshold_dbm FLOAT64 DEFAULT -105.0;

WITH hourly AS (
  SELECT
    satellite_id,
    ground_station_id,
    TIMESTAMP_TRUNC(event_time, HOUR) AS bucket,
    COUNT(*)                                    AS samples,
    ROUND(AVG(signal_strength_dbm), 2)          AS mean_dbm,
    ROUND(MIN(signal_strength_dbm), 2)          AS min_dbm,
    ROUND(APPROX_QUANTILES(signal_strength_dbm, 100)[OFFSET(5)], 2) AS p5_dbm,
    ROUND(AVG(bit_error_rate), 10)              AS mean_ber
  FROM `PROJECT.orbitalsense_dev.curated_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
    AND subsystem = 'comms'
    AND signal_strength_dbm IS NOT NULL
  GROUP BY satellite_id, ground_station_id, bucket
  HAVING COUNT(*) >= min_samples
),

flagged AS (
  SELECT *, mean_dbm < weak_threshold_dbm AS is_weak,
         -- Gaps-and-islands: group contiguous weak buckets into one run.
         ROW_NUMBER() OVER (PARTITION BY satellite_id ORDER BY bucket)
       - ROW_NUMBER() OVER (PARTITION BY satellite_id, mean_dbm < weak_threshold_dbm
                            ORDER BY bucket) AS run_id
  FROM hourly
),

runs AS (
  SELECT satellite_id, run_id,
         MIN(bucket) AS window_start,
         TIMESTAMP_ADD(MAX(bucket), INTERVAL 1 HOUR) AS window_end,
         COUNT(*) AS hours_weak,
         ROUND(AVG(mean_dbm), 2) AS run_mean_dbm,
         ROUND(MIN(min_dbm), 2)  AS run_min_dbm,
         STRING_AGG(DISTINCT ground_station_id ORDER BY ground_station_id) AS stations
  FROM flagged
  WHERE is_weak
  GROUP BY satellite_id, run_id
)

SELECT satellite_id, window_start, window_end, hours_weak,
       run_mean_dbm, run_min_dbm, stations
FROM runs
ORDER BY run_mean_dbm ASC, hours_weak DESC;