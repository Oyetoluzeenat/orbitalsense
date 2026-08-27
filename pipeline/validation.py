import json
from datetime import datetime, timezone, timedelta

MANDATORY_FIELDS = ["event_id", "satellite_id", "subsystem", "event_time"]
OPTIONAL_FIELDS  = ["sequence", "producer_version", "metrics"]

KNOWN_SUBSYSTEMS = {"power", "thermal", "comms", "orbital"}

# Plausibility bounds: physically possible range. Outside this -> quarantine.
# Nominal bounds: healthy operating range. Outside this but inside plausible -> alert.
BOUNDS = {
    "battery_voltage_v":     {"plausible": (18.0, 36.0),   "nominal": (26.0, 30.0)},
    "solar_array_current_a": {"plausible": (0.0, 30.0),    "nominal": (0.5, 12.0)},
    "temperature_c":         {"plausible": (-80.0, 150.0), "nominal": (-20.0, 55.0)},
    "signal_strength_dbm":   {"plausible": (-140.0, -20.0),"nominal": (-105.0, -60.0)},
    "bit_error_rate":        {"plausible": (0.0, 1.0),     "nominal": (0.0, 1e-4)},
    "altitude_km":           {"plausible": (300.0, 2000.0),"nominal": (500.0, 600.0)},
    "latitude_deg":          {"plausible": (-90.0, 90.0),  "nominal": (-90.0, 90.0)},
    "longitude_deg":         {"plausible": (-180.0, 180.0),"nominal": (-180.0, 180.0)},
}

MAX_CLOCK_SKEW = timedelta(seconds=60)
MAX_AGE        = timedelta(hours=24)


class Rejected(Exception):
    def __init__(self, code, detail="", field=None, value=None):
        self.code, self.detail, self.field, self.value = code, detail, field, str(value)
        super().__init__(f"{code}: {detail}")


def parse_event_time(raw):
    if not isinstance(raw, str):
        raise Rejected("WRONG_TYPE", "event_time is not a string", "event_time", raw)
    try:
        # Normalise the trailing Z; fromisoformat pre-3.11 rejects it
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        raise Rejected("UNPARSEABLE_TIMESTAMP", "event_time is not ISO-8601",
                       "event_time", raw)


def validate(record, now=None):
    """Return (clean_record, alert_code, alert_severity) or raise Rejected."""
    now = now or datetime.now(timezone.utc)

    if not isinstance(record, dict):
        raise Rejected("NOT_AN_OBJECT", f"top-level type was {type(record).__name__}")

    for f in MANDATORY_FIELDS:
        if f not in record or record[f] in (None, ""):
            raise Rejected("MISSING_MANDATORY_FIELD", f"'{f}' absent or empty", f)

    if record["subsystem"] not in KNOWN_SUBSYSTEMS:
        raise Rejected("UNKNOWN_SUBSYSTEM", f"'{record['subsystem']}' not recognised",
                       "subsystem", record["subsystem"])

    et = parse_event_time(record["event_time"])
    if et > now + MAX_CLOCK_SKEW:
        raise Rejected("TIMESTAMP_IN_FUTURE",
                       f"event_time is {(et - now).total_seconds():.0f}s ahead",
                       "event_time", record["event_time"])
    if et < now - MAX_AGE:
        raise Rejected("TIMESTAMP_TOO_OLD",
                       f"event_time is {(now - et).total_seconds() / 3600:.1f}h old",
                       "event_time", record["event_time"])

    seq = record.get("sequence")
    if seq is not None and (not isinstance(seq, int) or seq < 0):
        raise Rejected("INVALID_SEQUENCE", "sequence must be a non-negative integer",
                       "sequence", seq)

    metrics = record.get("metrics") or {}
    if not isinstance(metrics, dict):
        raise Rejected("WRONG_TYPE", "metrics is not an object", "metrics", metrics)
    if not metrics:
        raise Rejected("EMPTY_METRICS", "no metrics present")

    unknown = [k for k in metrics if k not in BOUNDS]
    if unknown:
        # Schema drift: parses fine, but we have no idea what these fields mean.
        # Quarantining is the right call — silently ignoring them is how a
        # renamed field becomes an invisible six-week outage.
        raise Rejected("SCHEMA_DRIFT", f"unrecognised metric field(s): {unknown}",
                       unknown[0], metrics.get(unknown[0]))

    alerts = []
    for k, v in metrics.items():
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise Rejected("WRONG_TYPE", f"metric '{k}' is {type(v).__name__}", k, v)
        lo, hi = BOUNDS[k]["plausible"]
        if not (lo <= v <= hi):
            raise Rejected("OUT_OF_BOUNDS",
                           f"{k}={v} outside plausible range [{lo}, {hi}]", k, v)
        nlo, nhi = BOUNDS[k]["nominal"]
        if not (nlo <= v <= nhi):
            alerts.append((k, v, nlo, nhi))

    alert_code = alert_severity = None
    if alerts:
        k, v, nlo, nhi = alerts[0]
        alert_code = f"{k.upper()}_OUT_OF_NOMINAL"
        margin = min(abs(v - nlo), abs(v - nhi)) / max(1e-9, (nhi - nlo))
        alert_severity = "CRITICAL" if margin > 0.5 else "WARNING"

    return record, alert_code, alert_severity