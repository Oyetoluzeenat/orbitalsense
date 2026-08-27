-- Battery health: level, dispersion, and degradation rate.
DECLARE window_hours INT64 DEFAULT 12;
DECLARE critical_v FLOAT64 DEFAULT 26.0;      -- from client discovery; parameterise
DECLARE slope_warn_v_per_day FLOAT64 DEFAULT -0.20;

WITH readings AS (
  SELECT satellite_id, event_time, battery_voltage_v
  FROM `PROJECT.orbitalsense_dev.curated_telemetry`
  WHERE ingest_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL window_hours HOUR)
    AND battery_voltage_v IS NOT NULL
),

stats AS (
  SELECT
    satellite_id,
    COUNT(*)                     AS n,
    ROUND(AVG(battery_voltage_v), 3)    AS avg_v,
    ROUND(MIN(battery_voltage_v), 3)    AS min_v,
    ROUND(STDDEV(battery_voltage_v), 3) AS stddev_v,
    -- Ordinary least squares slope: cov(t, v) / var(t), converted to V/day.
    ROUND(
      SAFE_DIVIDE(COVAR_POP(UNIX_SECONDS(event_time), battery_voltage_v),
                  VAR_POP(UNIX_SECONDS(event_time))) * 86400.0, 4)
                                 AS volts_per_day,
    ROUND(AVG(IF(event_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR),
                 battery_voltage_v, NULL)), 3) AS avg_v_last_hour
  FROM readings
  GROUP BY satellite_id
)

SELECT
  satellite_id, n, avg_v, avg_v_last_hour, min_v, stddev_v, volts_per_day,
  SAFE_DIVIDE(avg_v_last_hour - critical_v, -volts_per_day) AS days_to_critical,
  CASE
    WHEN n < 30                          THEN 'INSUFFICIENT_DATA'
    WHEN min_v < critical_v              THEN 'BREACHED'
    WHEN volts_per_day < slope_warn_v_per_day
     AND SAFE_DIVIDE(avg_v_last_hour - critical_v, -volts_per_day) < 30
                                         THEN 'DEGRADING_FAST'
    WHEN volts_per_day < slope_warn_v_per_day THEN 'DEGRADING'
    WHEN stddev_v > 1.0                  THEN 'UNSTABLE'
    ELSE 'NOMINAL'
  END AS health_status
FROM stats
ORDER BY volts_per_day ASC;