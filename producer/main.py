import os, json, time, uuid, random, logging, threading
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from google.cloud import pubsub_v1

import orbit
import faults

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("producer")

PROJECT_ID       = os.environ["PROJECT_ID"]
TOPIC_ID         = os.environ["TOPIC_ID"]
SAT_COUNT        = int(os.getenv("SATELLITE_COUNT", "12"))
SUBSYSTEMS       = os.getenv("SUBSYSTEMS", "power,thermal,comms,orbital").split(",")
EMIT_INTERVAL_S  = float(os.getenv("EMIT_INTERVAL_S", "2"))
MALFORMED_RATE   = float(os.getenv("MALFORMED_RATE", "0.02"))
DUPLICATE_RATE   = float(os.getenv("DUPLICATE_RATE", "0.03"))
PRODUCER_VERSION = os.getenv("PRODUCER_VERSION", "0.1.0")

publisher  = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

app = FastAPI()
_state = {"running": False, "published": 0, "corrupted": 0,
          "duplicated": 0, "buffered": 0, "started_at": None}
_manual_faults: list[str] = []
_lock = threading.Lock()

random.seed()
SATS     = orbit.build_constellation(SAT_COUNT)
BUFFERS  = {s.sat_id: orbit.SatelliteBuffer() for s in SATS}
SEQUENCE = {s.sat_id: 0 for s in SATS}

BLACKOUT_SAT        = random.choice(SATS).sat_id
BLACKOUT_START_S    = random.randint(180, 420)
BLACKOUT_DURATION_S = random.randint(300, 900)
log.info("BLACKOUT PLAN sat=%s start=+%ds duration=%ds",
         BLACKOUT_SAT, BLACKOUT_START_S, BLACKOUT_DURATION_S)


def sample_metrics(sat, subsystem, t):
    """Nominal values with slow drift, so trend analysis has something to find."""
    if subsystem == "power":
        idx = int(sat.sat_id.split("-")[1])
        degradation = 0.0006 * t if idx % 4 == 0 else 0.0    # one in four is dying
        return {
            "battery_voltage_v": round(random.gauss(28.0, 0.35) - degradation, 3),
            "solar_array_current_a": round(max(0.0, random.gauss(4.2, 0.6)), 3),
        }
    if subsystem == "thermal":
        return {"temperature_c": round(random.gauss(18.0, 9.0), 2)}
    if subsystem == "comms":
        return {
            "signal_strength_dbm": round(random.gauss(-92.0, 7.5), 2),
            "bit_error_rate": round(abs(random.gauss(1e-6, 4e-6)), 10),
        }
    lat, lon = sat.position(t)
    return {"altitude_km": round(random.gauss(551.0, 1.4), 3),
            "latitude_deg": round(lat, 4), "longitude_deg": round(lon, 4)}


def build_event(sat, subsystem, t):
    SEQUENCE[sat.sat_id] += 1
    return {
        "event_id": str(uuid.uuid4()),          # generated ONCE, here
        "satellite_id": sat.sat_id,
        "subsystem": subsystem,
        "sequence": SEQUENCE[sat.sat_id],
        "event_time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "producer_version": PRODUCER_VERSION,
        "metrics": sample_metrics(sat, subsystem, t),
    }


def publish(event, station, force_fault=None):
    mode = force_fault
    if mode is None and random.random() < MALFORMED_RATE:
        mode = random.choice(faults.FAULT_MODES)

    if mode:
        payload, applied = faults.corrupt(event, mode)
        with _lock: _state["corrupted"] += 1
        log.info("INJECT fault=%s sat=%s event_id=%s",
                 applied, event.get("satellite_id"), event.get("event_id"))
    else:
        payload = json.dumps(event).encode()

    attrs = {
        "ground_station_id": station,
        "satellite_id": str(event.get("satellite_id", "UNKNOWN")),
        "event_id": str(event.get("event_id", "")),
        "schema_version": "1",
    }
    publisher.publish(topic_path, payload, **attrs)
    with _lock: _state["published"] += 1

    # A duplicate is the SAME bytes and the SAME event_id, re-sent.
    if random.random() < DUPLICATE_RATE:
        time.sleep(random.uniform(0.05, 0.5))
        publisher.publish(topic_path, payload, **attrs)
        with _lock:
            _state["published"] += 1
            _state["duplicated"] += 1


def loop():
    t0 = time.time()
    while _state["running"]:
        t = time.time() - t0
        for sat in SATS:
            in_blackout = (sat.sat_id == BLACKOUT_SAT and
                           BLACKOUT_START_S <= t < BLACKOUT_START_S + BLACKOUT_DURATION_S)
            stations = [] if in_blackout else orbit.visible_stations(sat, t)
            subsystem = random.choice(SUBSYSTEMS)
            event = build_event(sat, subsystem, t)

            if not stations:
                BUFFERS[sat.sat_id].store(event)
                with _lock: _state["buffered"] += 1
                continue

            station = min(stations, key=lambda gs: orbit.great_circle_km(
                sat.position(t), orbit.GROUND_STATIONS[gs]))

            # Drain backlog first — this is what creates out-of-order arrival
            for old in BUFFERS[sat.sat_id].drain():
                publish(old, station)
            publish(event, station)

        with _lock:
            pending, _manual_faults[:] = list(_manual_faults), []
        for mode in pending:
            sat = random.choice(SATS)
            publish(build_event(sat, random.choice(SUBSYSTEMS), t), "GS-1", force_fault=mode)

        time.sleep(EMIT_INTERVAL_S)

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/stats")
def stats():
    return {**_state, "blackout_satellite": BLACKOUT_SAT,
            "blackout_start_s": BLACKOUT_START_S,
            "blackout_duration_s": BLACKOUT_DURATION_S}

@app.post("/start")
def start():
    if _state["running"]:
        return {"status": "already running"}
    _state["running"] = True
    _state["started_at"] = datetime.now(timezone.utc).isoformat()
    threading.Thread(target=loop, daemon=True).start()
    return {"status": "started"}

@app.post("/stop")
def stop():
    _state["running"] = False
    return {"status": "stopped"}

@app.post("/inject/{mode}")
def inject(mode: str, count: int = 1):
    """Live fault injection for the walkthrough."""
    if mode.upper() not in faults.FAULT_MODES:
        raise HTTPException(400, f"unknown mode; try {faults.FAULT_MODES}")
    with _lock:
        _manual_faults.extend([mode.upper()] * count)
    return {"queued": mode.upper(), "count": count}

@app.post("/inject/duplicates")
def inject_duplicates(count: int = 50):
    """Burst of duplicates — Section 8.1's second live fault."""
    sat = random.choice(SATS)
    event = build_event(sat, "power", time.time())
    payload = json.dumps(event).encode()
    for _ in range(count):
        publisher.publish(topic_path, payload,
                          ground_station_id="GS-2", satellite_id=sat.sat_id,
                          event_id=event["event_id"], schema_version="1")
    return {"burst": count, "event_id": event["event_id"], "satellite_id": sat.sat_id}
