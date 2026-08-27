## Deduplication: measured, not asserted

Before (pipeline_version 1.0.0-dev):
  21 events duplicated on the wire  →  42 rows in curated

After (pipeline_version 1.1.0-dedup):
  N events duplicated on the wire   →  N rows in curated

Raw retains all copies in both cases, deliberately: a repeat delivery is a fact
about the world, and raw's job is to record what arrived.
## Why curated exists — measured, not asserted

Query 2's slope, run against 14 days of unvalidated historical telemetry
(~8,200 POWER readings per satellite):

  min_v ≈ -39 V on every satellite; slopes range -0.018 to +0.024 V/day.

The same query with plausibility bounds applied (18–36 V):

  min_v = 27.45 V on every satellite; slopes range -0.003 to +0.003 V/day.

The generator gives all twelve satellites an identical voltage model, so the
true slope spread is near zero. The unvalidated version manufactures an eight-
fold spread out of 2% injected bad records, and ranks SAT-07 as the fastest
decliner. That conclusion is wrong, and nothing about the query or the data
signals it.

This is the Trust objective in one comparison: a value that parses is not a
value that can be believed.

## Query 3 validation against a known answer

Run blind against 14 days of historical telemetry, the weakest-signal query
returned SAT-11 at -98.51 dBm mean, against -65 dBm for all eleven others,
with 5,328 LOST and 2,894 DEGRADED statuses where the rest recorded none.

The dataset's answer key names SAT-11 as the deliberately degraded satellite.
The query found it without being told what to look for.
