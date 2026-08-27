import json, random, copy
from datetime import datetime, timedelta, timezone

FAULT_MODES = [
    "MALFORMED_JSON",     # truncated bytes — cannot be parsed at all
    "WRONG_TYPE",         # voltage as the string "N/A"
    "IMPOSSIBLE_VALUE",   # parses fine, physically absurd
    "RENAMED_FIELD",      # schema drift: battery_voltage_v -> batteryVoltage
    "MISSING_FIELD",      # mandatory field absent
    "FUTURE_TIMESTAMP",   # event_time two hours ahead
    "NEGATIVE_SEQUENCE",
]


def corrupt(event: dict, mode: str) -> tuple[bytes, str]:
    """Return (payload_bytes, applied_mode). Payload may be invalid JSON."""
    e = copy.deepcopy(event)

    if mode == "MALFORMED_JSON":
        return json.dumps(e).encode()[: random.randint(20, 60)], mode
    if mode == "WRONG_TYPE":
        for k in e["metrics"]:
            e["metrics"][k] = "N/A"
            break
    elif mode == "IMPOSSIBLE_VALUE":
        if "battery_voltage_v" in e["metrics"]:
            e["metrics"]["battery_voltage_v"] = 9999.0
        else:
            k = next(iter(e["metrics"]))
            e["metrics"][k] = -1e9
    elif mode == "RENAMED_FIELD":
        if "battery_voltage_v" in e["metrics"]:
            e["metrics"]["batteryVoltage"] = e["metrics"].pop("battery_voltage_v")
        elif "signal_strength_dbm" in e["metrics"]:
            e["metrics"]["signalStrength"] = e["metrics"].pop("signal_strength_dbm")
    elif mode == "MISSING_FIELD":
        e.pop(random.choice(["satellite_id", "event_time", "subsystem"]), None)
    elif mode == "FUTURE_TIMESTAMP":
        e["event_time"] = (datetime.now(timezone.utc) + timedelta(hours=2)) \
            .isoformat().replace("+00:00", "Z")
    elif mode == "NEGATIVE_SEQUENCE":
        e["sequence"] = -abs(e.get("sequence", 1))

    return json.dumps(e).encode(), mode