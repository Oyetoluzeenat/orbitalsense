import json, hashlib, logging
from datetime import datetime, timezone

import apache_beam as beam
from apache_beam import pvalue

import validation

RAW = "raw"
QUARANTINE = "quarantine"

METRIC_COLUMNS = [
    "battery_voltage_v", "solar_array_current_a", "temperature_c",
    "signal_strength_dbm", "bit_error_rate", "altitude_km",
    "latitude_deg", "longitude_deg",
]


def _iso(dt):
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class ProcessTelemetry(beam.DoFn):
    """Single pass: emit raw, then either curated (main) or quarantine."""

    def __init__(self, pipeline_version, allowed_lateness_s):
        self.pipeline_version = pipeline_version
        self.allowed_lateness_s = allowed_lateness_s

    def process(self, message):
        now = datetime.now(timezone.utc)
        ingest_time = _iso(now)
        attrs = dict(message.attributes or {})
        station = attrs.get("ground_station_id", "UNKNOWN")
        msg_id = attrs.get("_pubsub_message_id") or getattr(message, "message_id", None)

        publish_time = None
        if "_pubsub_publish_time" in attrs:
            publish_time = attrs["_pubsub_publish_time"]

        try:
            text = message.data.decode("utf-8")
        except UnicodeDecodeError:
            text = repr(message.data)

        # 1. RAW — always, unconditionally, unmodified. This happens before any
        #    validation so that even undecodable garbage is recoverable.
        yield pvalue.TaggedOutput(RAW, {
            "ingest_time": ingest_time,
            "publish_time": publish_time,
            "pubsub_message_id": msg_id,
            "ground_station_id": station,
            "attributes_json": json.dumps(attrs, sort_keys=True),
            "payload": text[:900000],
            "payload_sha256": hashlib.sha256(message.data).hexdigest(),
            "pipeline_version": self.pipeline_version,
        })

        def reject(code, detail="", field=None, value=None, rec=None):
            rec = rec or {}
            return pvalue.TaggedOutput(QUARANTINE, {
                "ingest_time": ingest_time,
                "publish_time": publish_time,
                "pubsub_message_id": msg_id,
                "event_id": rec.get("event_id") or attrs.get("event_id") or None,
                "satellite_id": rec.get("satellite_id") or attrs.get("satellite_id"),
                "subsystem": rec.get("subsystem"),
                "ground_station_id": station,
                "reason_code": code,
                "reason_detail": detail[:1000],
                "offending_field": field,
                "offending_value": (str(value)[:500] if value is not None else None),
                "raw_payload": text[:100000],
                "pipeline_version": self.pipeline_version,
            })

        # 2. PARSE
        try:
            record = json.loads(text)
        except json.JSONDecodeError as e:
            yield reject("MALFORMED_JSON", str(e))
            return

        # 3. VALIDATE
        try:
            record, alert_code, alert_severity = validation.validate(record, now=now)
        except validation.Rejected as r:
            yield reject(r.code, r.detail, r.field, r.value, rec=(record if isinstance(record, dict) else None))
            return
        except Exception as e:                      # never let one bad row kill the bundle
            logging.exception("unexpected validation failure")
            yield reject("VALIDATION_ERROR", f"{type(e).__name__}: {e}")
            return

        # 4. ENRICH
        event_dt = validation.parse_event_time(record["event_time"])
        lag = (now - event_dt).total_seconds()
        metrics = record.get("metrics") or {}

        curated = {
            "event_id": record["event_id"],
            "satellite_id": record["satellite_id"],
            "subsystem": record["subsystem"],
            "sequence": record.get("sequence"),
            "event_time": _iso(event_dt),
            "ingest_time": ingest_time,
            "publish_time": publish_time,
            "ground_station_id": station,
            "lag_seconds": round(lag, 3),
            "is_late": lag > 60,
            "beyond_allowed_lateness": lag > self.allowed_lateness_s,
            "metrics_json": json.dumps(metrics, sort_keys=True),
            "alert_code": alert_code,
            "alert_severity": alert_severity,
            "producer_version": record.get("producer_version"),
            "pipeline_version": self.pipeline_version,
        }
        for col in METRIC_COLUMNS:
            curated[col] = metrics.get(col)

        yield curated          # main output

def dedup_key(record):
    """Key on facts the SPACECRAFT asserted, never on facts WE derived.

    A key computed after ingestion metadata is attached hashes differently for
    every copy, so deduplication reports healthy and catches nothing — with no
    error and no log line.
    """
    return record["event_id"]


def fallback_dedup_key(record):
    """Natural composite key, if event_id were ever absent."""
    return "|".join([
        record["satellite_id"],
        record["subsystem"],
        record["event_time"],
        str(record.get("sequence", "")),
    ])
