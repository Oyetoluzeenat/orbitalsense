## Deduplication: measured, not asserted

Before (pipeline_version 1.0.0-dev):
  21 events duplicated on the wire  →  42 rows in curated

After (pipeline_version 1.1.0-dedup):
  20 identical copies of one event_id  →  1 row in curated
  (verified by direct publish; raw retained all 20)

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

## Producer visibility and message ordering

Visibility is geometric, not random. Each satellite's sub-satellite point is
propagated from a circular-orbit model and compared against fixed ground-station
coordinates using great-circle distance with a 2,200 km horizon. When more than
one station is in view the nearest wins, modelling a scheduler's link-budget
preference. When none is in view, telemetry is buffered on board in a bounded
FIFO of 500 events and drained on next contact.

Measured: 17% coverage across 12 satellites and 4 stations. In one run the
producer held 795 events buffered against 290 published — more than twice as
much telemetry waiting on board as had been transmitted.

The model is deliberately crude: circular orbits, spherical Earth, no J2
perturbation. Orbital accuracy is not the point. The point is that coverage gaps
emerge from geometry rather than from `random.random() < 0.3`.

This affects ordering three ways. Buffer drains interleave old and new events,
so arrival order does not match event order. Handovers move a satellite's stream
between publishers, and Pub/Sub only guarantees ordering within an ordering key
for a single publisher. Relay latency differs per station, so two events emitted
in order can overtake each other in flight.

Arrival order therefore carries no information, and all correctness downstream is
anchored to producer-supplied `event_time` and a stable `event_id`. Pub/Sub
message ordering was deliberately not enabled: it serialises delivery per key and
adds head-of-line blocking to buy a guarantee that a station handover breaks
anyway.

## Late versus malformed

These are orthogonal axes. *Validity* is a property of content — does it parse,
are mandatory fields present, are the values physically possible. *Lateness* is a
property of timing — how far is ingestion time behind event time. A message can
be early and malformed, or four hours late and perfectly valid.

Validity determines destination. Lateness determines annotation.

Measured: of 763 curated rows in one run, 609 were flagged `is_late` with a worst
lag of 648 seconds. Every one is valid telemetry, arriving late because a
satellite buffered it during a coverage gap. None were quarantined. Discarding
them would lose exactly the telemetry from the period a satellite was out of
contact — which is when you most want it.

Beyond `allowed_lateness_minutes` (45, sized to cover the GS-3 constraint with
margin), windowed aggregates have closed and will not be amended. Those records
are still written, flagged `beyond_allowed_lateness`, so the raw fact is
preserved and any rollup that excluded them is auditable.

The one hard limit is `TIMESTAMP_TOO_OLD` at 24 hours. That is a plausibility
rule, not a lateness policy: an event claiming to be from last week is far more
likely a clock fault than a genuine spacecraft buffer, and admitting it would
corrupt historical partitions.

## Retention and lifecycle

| Layer | Retention | Reasoning |
|---|---|---|
| Raw (GCS archive) | Nearline at 30 days, deleted at 90 | Exists for replay and proof of receipt; reprocessing value decays sharply after a month |
| Raw (BigQuery) | 90-day partition expiry | After 90 days, curated plus quarantine answer any question raw could |
| Curated | 400 days | Outlives any investigation or annual comparison |
| Quarantine | 400 days | Outlives raw deliberately: data-quality investigations start late, and the table is small |
| Dataflow temp | 7 days | Scratch. Soft delete disabled — Dataflow churns temp files and would otherwise bill for 7 days of deletions |

The tension worth naming: shortening raw retention saves storage but shrinks the
replay window, and the replay window is the real disaster-recovery budget.
Pub/Sub's 7 days is the first line; raw is the second.

## Partitioning and clustering

Partition on `ingest_time`, not `event_time`. Ingestion time is monotonic and
bounded, so a late message from an hour ago lands in today's partition. Old
partitions are never rewritten, and a single bad future timestamp cannot blow the
partition limit. Event time is the analytically correct axis, which is why every
query filters on both.

| Table | Cluster | Justified by |
|---|---|---|
| `curated_telemetry` | `satellite_id`, `subsystem` | Queries 1–4 group or filter by satellite; 2 and 3 also filter by subsystem |
| `quarantine_telemetry` | `reason_code`, `ground_station_id` | The only questions asked of quarantine: what kind of failure, which station |
| `raw_telemetry` | `ground_station_id` | Station-level receipt audits |

`require_partition_filter` is on for raw and off for curated. Raw is the largest
table and nobody should full-scan it by accident; curated is where analysts
explore, and a hard failure there is hostile.

If the query pattern shifted, clustering is cheap to change (`CREATE OR REPLACE
TABLE ... CLUSTER BY` plus a backfill) and partitioning is not (a full rewrite).
The expensive-to-change decision therefore sits on the stable axis, and the
cheap-to-change decision on the volatile one.

**Caveat, stated honestly:** curated currently holds a few thousand rows, well
under BigQuery's block size, so a bytes-scanned comparison shows no measurable
clustering benefit yet. The justification above is architectural, not empirical.
At production volume the measurement would be straightforward.

## Least privilege: one role was too narrow

The Dataflow service account was granted `roles/pubsub.subscriber` on the
subscription — resource-scoped, minimal, sufficient to pull messages. The job
ran, but the log showed:

    GETTING_PUBSUB_SUBSCRIPTION_FAILED: not authorized to perform this action

`subscriber` permits pulling but not `pubsub.subscriptions.get`, which Dataflow
needs for backlog reporting and Streaming Engine bookkeeping. Adding
`roles/pubsub.viewer` resolved it.

The narrowest role that lets a component do its primary job is not always the
narrowest role it needs. Found by reading the job log, fixed in Terraform rather
than the console.

## Query 3 validated against a known answer

Run blind against 14 days of historical telemetry, the weakest-signal query
returned SAT-11 at -98.51 dBm mean against -65 dBm for all eleven others, with
5,328 LOST and 2,894 DEGRADED statuses where the rest recorded none.

The dataset's answer key names SAT-11 as the deliberately degraded satellite. The
query found it without being told what to look for.

## What breaks at 12 → 1,200 satellites

Not Pub/Sub — it is built for far more than 100× this and needs no change. Not
BigQuery storage. Three things break, in this order.

**First, the producer, and structurally rather than on capacity.** It is a single
Cloud Run instance pinned to `max_instance_count = 1`, holding the entire
constellation's orbital state, per-satellite sequence numbers and on-board
buffers in process memory. Two instances would each simulate all 1,200
satellites, so it cannot scale horizontally without sharding the constellation.

This is not theoretical. When Cloud Run replaced the instance mid-run, the
producer restarted with `published: 0` and a freshly randomised blackout plan —
all in-memory state gone. That is the same limitation seen from a different
angle: state in process memory prevents both restart resilience and horizontal
scaling.

Fix: shard by satellite ID range via an environment variable, externalise buffers
to Memorystore or accept their loss on restart, lift the instance cap. Roughly
half a day.

**Second, BigQuery streaming inserts.** At about 100× the row rate this
approaches per-table streaming quotas, and per-row insert cost becomes the
dominant line item. Fix: switch the sink to the Storage Write API, or to
`FILE_LOADS` with a 60-second triggering frequency — trading a minute of latency
for a large cost reduction. The Timeliness objective says "within minutes", so a
60-second batch remains inside the requirement.

**Third, deduplication state.** `DeduplicatePerKey` holds one key per distinct
`event_id` per 60-minute window. At 1,200 satellites × 4 subsystems × 30
events/minute that is tens of millions of live keys. Streaming Engine moves it
off the workers, but it remains the component most likely to force scale-up.
Fix: shorten the window to the smallest value covering Pub/Sub's redelivery
envelope — ack deadline × max attempts, so roughly 5 minutes rather than 60 —
and push final idempotency to the sink.

## The cheapest change that buys the most headroom

Move the BigQuery sink from streaming inserts to the Storage Write API.

It is roughly a one-line change to the `WriteToBigQuery` call. It requires no
re-architecture, no new services, and no change to the data model. It
simultaneously removes the quota ceiling, cuts the largest per-unit cost, and
provides stronger delivery semantics at the sink than we have today —
which also partly addresses the known gap below.

Everything else on the scaling list costs days. This costs an hour.

## Known gaps

- **Failed BigQuery inserts are not captured into quarantine.** The sink's
  failed-rows output should route there. This is the one hop in the message
  journey with an open loss path.
- **The producer does not flush the Pub/Sub client on SIGTERM.** The client
  batches asynchronously; an instance terminating with unflushed batches loses
  them.
- **Deduplication is bounded and best-effort.** A duplicate arriving beyond the
  60-minute window is not caught. State cost scales with distinct keys × window,
  so this is a sizing trade rather than an oversight. End-to-end exactly-once
  would need idempotency at the sink — `MERGE` on `event_id` — not more state in
  Beam.
- **No Cloud Monitoring dashboards.** A stalled producer and a stalled pipeline
  look identical from BigQuery. An alert on the subscription's oldest
  unacked-message age is what distinguishes them.

## Fault drills — measured against the deployed system

Each fault was published directly to the Pub/Sub topic, bypassing the producer,
so the pipeline's classification is demonstrated independently of the simulator.

**Drill 1 — valid JSON, physically impossible value.**

    event_id: drill-1, battery_voltage_v: 9999.0
    → OUT_OF_BOUNDS
      offending_field: battery_voltage_v
      offending_value: 9999.0
      reason_detail:   "battery_voltage_v=9999.0 outside plausible range [18.0, 36.0]"

The value parses as a number. It is not a satellite in trouble; it is a corrupt
reading, and admitting it would poison every average in the platform.

**Drill 2 — silently renamed field.**

    event_id: drill-2, subsystem: comms, metrics: {"signalStrength": -95.0}
    → SCHEMA_DRIFT
      offending_field: signalStrength
      offending_value: -95.0
      reason_detail:   "unrecognised metric field(s): ['signalStrength']"

This is the failure the fourth analytics question is built around. The message
is valid JSON and parses cleanly; the pipeline simply does not recognise the
field. Because it never reaches curated, it can never raise an alert — so comms
appears to have the fewest alerts and reads as the healthiest subsystem. It is
not. Query 4 exposes this by joining alert counts against quarantine, and the
rejection rate plus the offending field name give the diagnosis directly.

A pipeline that dropped malformed data silently would have shown comms green
indefinitely.

**Drill 3 — duplicate burst.**

    20 identical publishes of one event_id
    → 20 rows in raw_telemetry, 1 row in curated_telemetry

Raw records every delivery because a repeat delivery is a fact about the world.
Curated records the event once.

Each drill was located by a single targeted query on `event_id`, in under a
minute. See `sql/proofs/drill_lookup.sql`.

## Reconciliation — every message accounted for

One hour on the deployed Dataflow pipeline:

    raw         7,688
    curated     7,274
    quarantined   158
    difference    256  (duplicates suppressed, 3.3% — matches the injected rate)

raw = curated + quarantined + duplicates suppressed.

An earlier version of this check reported curated exceeding raw, which is
impossible. The cause was in the query, not the pipeline: raw was filtered to
the last hour while curated and quarantine counted all history. Windows must
match for the identity to hold.

## Worker-loss recovery — measured

A Dataflow worker VM was deleted mid-stream while the pipeline was processing
live telemetry.

Per-minute ingestion into raw_telemetry:

    07:02   122   worker deleted
    07:03     0   gap
    07:04     0   gap
    07:05   506   recovery: Pub/Sub redelivers the unacknowledged backlog
    07:06    59   settled

The job never left the Running state. Dataflow detected the lost worker and
provisioned a replacement without failing the job.

Messages in flight were never acknowledged, so Pub/Sub redelivered them once the
60-second ack deadline expired — visible as the 506-row burst at 07:05 against a
steady-state rate of roughly 60 per minute. Those redeliveries are true
duplicates by our definition, carrying the same producer-assigned event_id, and
were suppressed by DeduplicatePerKey. Deduplication state survived the worker
loss because Streaming Engine holds it off the worker rather than in worker
memory.

A gap in ingest rate; no gap in coverage. No manual intervention, no rerun
script.
