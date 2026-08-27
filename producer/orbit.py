import math
from dataclasses import dataclass, field

EARTH_RADIUS_KM = 6371.0

GROUND_STATIONS = {
    "GS-1": (78.23, 15.39),    # Svalbard
    "GS-2": (-33.93, 18.42),   # Cape Town
    "GS-3": (-72.00, 2.53),    # Troll, Antarctica
    "GS-4": (13.08, 80.27),    # Chennai
}

# A LEO satellite at ~550 km is visible to a station within roughly this
# great-circle radius at a 10-degree minimum elevation mask.
VISIBILITY_RADIUS_KM = 2200.0


@dataclass
class Satellite:
    sat_id: str
    period_s: float        # ~95 min for a 550 km circular LEO
    inclination_deg: float
    phase_rad: float       # where it is in its orbit at t=0
    raan_deg: float        # right ascension of ascending node

    def position(self, t: float) -> tuple[float, float]:
        """Return (latitude_deg, longitude_deg) of the sub-satellite point."""
        theta = self.phase_rad + 2 * math.pi * (t / self.period_s)
        inc = math.radians(self.inclination_deg)

        lat = math.degrees(math.asin(math.sin(inc) * math.sin(theta)))
        # Longitude advances with the orbit and regresses with Earth's rotation
        lon_orbit = math.degrees(math.atan2(math.cos(inc) * math.sin(theta), math.cos(theta)))
        earth_rot = 360.0 * (t / 86400.0)
        lon = ((self.raan_deg + lon_orbit - earth_rot + 180.0) % 360.0) - 180.0
        return lat, lon


def great_circle_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(h))


def visible_stations(sat: Satellite, t: float) -> list[str]:
    pos = sat.position(t)
    return [
        gs for gs, gs_pos in GROUND_STATIONS.items()
        if great_circle_km(pos, gs_pos) <= VISIBILITY_RADIUS_KM
    ]


def build_constellation(n: int) -> list[Satellite]:
    """Spread n satellites across 3 orbital planes for realistic coverage gaps."""
    sats = []
    for i in range(n):
        plane = i % 3
        sats.append(Satellite(
            sat_id=f"SAT-{i + 1:02d}",
            period_s=95 * 60 + (i % 5) * 7,          # slight period spread
            inclination_deg=[97.5, 53.0, 81.0][plane],
            phase_rad=(2 * math.pi) * ((i // 3) / max(1, n // 3)),
            raan_deg=plane * 120.0 + (i * 7) % 40,
        ))
    return sats

@dataclass
class SatelliteBuffer:
    """Finite on-board storage.

    This single behaviour generates out-of-order arrival, genuinely late
    data, and bursts — the three conditions the pipeline must survive.
    """

    MAX_BUFFER: int = 500
    pending: list = field(default_factory=list)
    dropped_onboard: int = 0

    def store(self, event: dict) -> None:
        if len(self.pending) >= self.MAX_BUFFER:
            self.pending.pop(0)          # oldest wins the eviction
            self.dropped_onboard += 1
        self.pending.append(event)

    def drain(self, max_items: int = 25) -> list:
        out, self.pending = self.pending[:max_items], self.pending[max_items:]
        return out

def nearest_station(sat: Satellite, t: float, candidates: list) -> str:
    """Nearest station wins, modelling a scheduler's link-budget preference."""
    pos = sat.position(t)
    return min(candidates, key=lambda gs: great_circle_km(pos, GROUND_STATIONS[gs]))
