# OrbitalSense

Cloud-native satellite telemetry platform on Google Cloud.

OrbitalSense ingests engineering telemetry from twelve Earth-observation
satellites, relayed through four ground stations, and makes it queryable within
minutes. It validates every reading against schema and physical-plausibility
rules before it reaches the curated layer, quarantines whatever it rejects with a
reason code rather than dropping it silently, and survives duplicate delivery,
out-of-order arrival, satellite dropout and malformed payloads without manual
intervention. Every resource is declared in Terraform, so the environment can be
destroyed and rebuilt from nothing.

| | Commitment | In practice |
|---|---|---|
| 1 | **Trust** | If a value is in curated, it is believed to be a real reading — not a symbol that happened to parse |
| 2 | **Timeliness** | Anomalies are queryable within minutes, not after a nightly batch |
| 3 | **Completeness** | Nothing is dropped silently; every rejection carries a reason code and the offending field |

---

## Architecture

![Architecture](docs/architecture.png)

Failure paths are red, the unconditional write to raw is grey, replay is green.

Two failure destinations, and they are **not** interchangeable. The Pub/Sub
dead-letter topic catches *infrastructure* failure — crashes, out-of-memory,
repeatedly unacknowledged delivery. The quarantine table catches *data* failure —
bad JSON, an impossible voltage, a renamed field. A malformed payload appearing
in the dead-letter topic would mean the pipeline is throwing rather than
classifying, and the no-silent-drops guarantee would not hold.

---

## How a message travels

![Message journey](docs/message-journey.png)

Nine hops from spacecraft to queryable row. Three carry genuine loss risk, one
discards data deliberately, and five lose nothing — with the reason stated rather
than asserted in each case.

`raw = curated + quarantined + duplicates suppressed`. If those numbers do not
add up, one of the nine hops is losing data.

---

## Event contract

Message body, JSON:

```json
{
  "event_id": "8f2a1c30-6d4e-4b21-9f0a-2b3c4d5e6f70",
  "satellite_id": "SAT-07",
  "subsystem": "power",
  "sequence": 4821,
  "event_time": "2026-08-21T10:14:03.220Z",
  "producer_version": "0.1.0",
  "metrics": {
    "battery_voltage_v": 27.84,
    "solar_array_current_a": 4.11
  }
}
```

Published with Pub/Sub **attributes**, outside the body:

```
ground_station_id = "GS-3"
satellite_id      = "SAT-07"
event_id          = "8f2a1c30-..."
schema_version    = "1"
```

Two decisions worth stating explicitly.

**`ground_station_id` is an attribute, not a body field.** The satellite does not
know which station heard it — the station does. Putting station identity in the
body would model a fact the spacecraft cannot have. It also means the value is
readable without deserialising the payload, and it keeps ground-segment metadata
cleanly separable from spacecraft telemetry.

**`event_id` is generated once, at creation, and reused on every resend.** This
is the entire basis of deduplication downstream. If a resend received a fresh
identifier it would not be a duplicate, it would be a new fact, and nothing later
in the system could tell the two apart.

---

## Repository layout

```
infra/       Terraform: the entire environment, plus bootstrap/ for remote state
producer/    Containerised telemetry simulator with a live fault-injection API
pipeline/    Streaming Apache Beam pipeline
sql/         The four operational analytics queries, plus proofs/
docs/        Diagrams, deployment guide, design rationale, discovery answers
scripts/     deploy_producer.sh, launch_pipeline.sh, inject_fault.sh
```

---

## Quick start

```bash
export PROJECT_ID="your-project" REGION="europe-west1" ENV="dev"

make bootstrap                       # remote state bucket, once per project
make init                            # point Terraform at it
cd infra && terraform apply -var-file=envs/dev.tfvars && cd ..
gcloud builds submit producer/ \
  --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/orbitalsense/producer:0.1.1
cd infra && terraform apply -var-file=envs/dev.tfvars && cd ..

./scripts/launch_pipeline.sh         # Dataflow job
./scripts/inject_fault.sh start      # begin telemetry
```

The apply appears twice deliberately. Terraform creates the Artifact Registry
repository, so the image cannot be built until after the first apply; Cloud Run
cannot start until after the image exists. The first apply will report a Cloud
Run failure, and that is expected.

Verify:

```bash
./scripts/inject_fault.sh stats       # producer counters and the blackout plan
./scripts/inject_fault.sh verify      # reconciliation
./scripts/inject_fault.sh quarantine  # rejection breakdown
```

Stop cleanly — a streaming Dataflow job bills until cancelled:

```bash
./scripts/inject_fault.sh stop
./scripts/launch_pipeline.sh --cancel
```

Full instructions: [`docs/deployment-guide.md`](docs/deployment-guide.md).

---

## Configuration

Everything the client might change is a variable, so a constraint arriving
mid-project costs a one-line edit rather than a code change.

| Variable | Default | Change it when |
|---|---|---|
| `satellite_count` | 12 | A different constellation size is issued |
| `ground_stations` | GS-1 … GS-4 | The station list changes |
| `subsystems` | power, thermal, comms, orbital | The subsystem list changes |
| `allowed_lateness_minutes` | 45 | A delivery-delay constraint is revealed |
| `dedup_window_minutes` | 60 | Memory pressure, or a longer redelivery envelope |
| `raw_retention_days` | 90 | The client answers the retention question |
| `producer_min_instances` | 0 | Continuous telemetry is needed — set to 1 |
| `malformed_rate` / `duplicate_rate` | 0.02 / 0.03 | The corruption profile changes |
| `pipeline_version` | 1.0.0 | Every deployment — this is what makes rollback safe |

---

## Design decisions

### Visibility and message ordering

Visibility is computed geometrically. Each satellite's sub-satellite point is
propagated from a circular-orbit model and compared against fixed ground-station
coordinates using great-circle distance with a 2,200 km horizon. When more than
one station is in view the nearest wins, modelling a real scheduler's link-budget
preference. When no station is in view, telemetry is buffered on board in a
bounded FIFO of 500 events and drained on the next contact.

The model is deliberately crude — circular orbits, spherical Earth, no J2
perturbation. Orbital accuracy is not the point. The point is that coverage gaps
emerge from geometry rather than from `random.random() < 0.3`. Measured coverage
is roughly 17%, and in one run the producer held 795 events buffered against 290
published: more than twice as much telemetry waiting on board as transmitted.

This affects ordering in three ways:

- **Buffer drains interleave old and new events**, so arrival order does not
  match event order.
- **Handovers move a satellite's stream between publishers.** Pub/Sub guarantees
  ordering only within an ordering key for a single publisher, so even ordered
  publishing would not survive a handover.
- **Relay latency differs per station**, so two events emitted in order can
  overtake each other in flight.

Arrival order therefore carries no information. All correctness downstream is
anchored to producer-supplied `event_time` and a stable `event_id`.

Pub/Sub message ordering was deliberately **not** enabled. It would serialise
delivery per key, cutting throughput and adding head-of-line blocking, to buy a
guarantee that a station handover breaks anyway. Event-time processing in Beam
solves the real problem more cheaply.

### Late is not malformed

These are orthogonal axes. *Validity* is a property of content — does it parse,
are mandatory fields present, are the values physically possible. *Lateness* is a
property of timing — how far ingestion time trails event time. A message can be
early and malformed, or four hours late and perfectly valid.

Validity determines destination. Lateness determines annotation.

Late-but-valid data is never quarantined. It lands in curated with
`is_late = TRUE` and `lag_seconds` recorded. In one run, 609 of 763 curated rows
were flagged late with a worst lag of 648 seconds — every one of them valid
telemetry that a satellite had buffered during a coverage gap. Discarding them
would lose exactly the telemetry from the period a satellite was out of contact,
which is when it matters most.

Beyond allowed lateness the windowed aggregates have closed and will not be
amended, but the records are still written, flagged `beyond_allowed_lateness`, so
the raw fact is preserved and any rollup that excluded them is auditable.

The one hard limit is `TIMESTAMP_TOO_OLD` at 24 hours. That is a plausibility
rule rather than a lateness policy: an event claiming to be from last week is far
more likely a clock fault than a genuine spacecraft buffer.

### Plausible is not the same as abnormal

A battery voltage of 9,999 V is not a satellite in trouble. It is a corrupt
reading, and admitting it would poison every average in the platform, so it is
quarantined as `OUT_OF_BOUNDS`.

A battery voltage of 24.1 V is physically possible but outside nominal. It is a
genuine alert, and belongs in curated with an alert code.

Conflating the two either poisons the analytics or produces an alerting system
that operators learn to ignore. This distinction is the Trust objective in one
sentence.

### Deduplication

Keyed on `event_id` — derived only from facts the spacecraft asserted, never from
facts the pipeline derived.

The failure mode worth naming: a key computed *after* ingestion metadata is
attached hashes differently for every copy, because `ingest_time` has microsecond
precision and `pubsub_message_id` is unique per delivery by definition.
Deduplication then runs, reports healthy, and catches nothing. No exception, no
log line, just quietly doubled counts.

The guard against that regressing is a metric, not a code review. A deduplication
step whose input and output counts are always identical is not deduplicating.

Raw is deliberately **not** deduplicated. If the same bytes arrived twice, that is
a fact about the world, and raw's job is to record what arrived.

### Retention and lifecycle

| Layer | Retention | Reasoning |
|---|---|---|
| Raw (GCS) | Nearline at 30 days, deleted at 90 | Exists for replay and proof of receipt; reprocessing value decays sharply after a month |
| Raw (BigQuery) | 90-day partition expiry | Beyond that, curated plus quarantine answer any question raw could |
| Curated | 400 days | Outlives any investigation or annual comparison |
| Quarantine | 400 days | Outlives raw deliberately — data-quality investigations start late, and the table is small |
| Dataflow temp | 7 days | Scratch, with soft delete disabled so churned temp files are not billed for a week |

The tension worth naming: shortening raw retention saves storage but shrinks the
replay window, and the replay window is the real disaster-recovery budget.

### Partitioning and clustering

Partition on `ingest_time`, not `event_time`. Ingestion time is monotonic and
bounded, so a late message from an hour ago lands in today's partition — old
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

If the query pattern shifted, clustering is cheap to change and partitioning is
not. The expensive-to-change decision therefore sits on the stable axis, and the
cheap-to-change decision on the volatile one.

---

## What the numbers show

Every claim in this repository is backed by a measurement from a run of this
system, not by an assertion about how it ought to behave.

### Deduplication

| | Duplicated on the wire | Rows in curated |
|---|---|---|
| Before (`1.0.0-dev`) | 21 events | 42 |
| After (`1.1.0-dedup`) | 20 identical copies of one `event_id` | 1 |

Raw retained all 20 copies in the second case. Both behaviours coexist in the
same table, filterable by `pipeline_version`.

### Reconciliation

One hour on the deployed Dataflow pipeline:

```
raw          7,688
curated      7,274
quarantined    158
difference     256   duplicates suppressed — 3.3%, matching the injected rate
```

An earlier version of this check reported curated exceeding raw, which is
impossible. The cause was in the query, not the pipeline: raw was filtered to the
last hour while curated and quarantine counted all history. The windows must
match for the identity to hold.

### Why curated exists

Query 2's battery slope, run against 14 days of unvalidated historical telemetry
(~8,200 power readings per satellite):

```
minimum voltage ≈ -39 V on every satellite
slopes range    -0.018 to +0.024 V/day
```

The same query with plausibility bounds applied:

```
minimum voltage = 27.45 V on every satellite
slopes range    -0.003 to +0.003 V/day
```

The generator gives all twelve satellites an identical voltage model, so the true
slope spread is near zero. The unvalidated version manufactures an eightfold
spread out of 2% injected bad records, and confidently ranks one satellite as the
fastest decliner. That conclusion is wrong, and nothing about the query or the
data signals it.

### Fault classification

Seven distinct reason codes observed in production runs, each recording the
offending field and value:

```
OUT_OF_BOUNDS            battery_voltage_v = 9999.0
SCHEMA_DRIFT             signalStrength     (renamed field)
WRONG_TYPE               temperature_c is str
MISSING_MANDATORY_FIELD  satellite_id absent
TIMESTAMP_IN_FUTURE      event_time 6,751s ahead
INVALID_SEQUENCE         negative sequence
MALFORMED_JSON           unterminated string
```

`SCHEMA_DRIFT` is the one that matters most. A station emitting `signalStrength`
instead of `signal_strength_dbm` produces valid JSON that parses cleanly, but the
pipeline does not recognise the field. Those messages never reach curated, so
comms can never raise an alert — and the alert count alone would read as
"healthiest subsystem". Query 4 exposes this by joining alerts against
quarantine.

### Worker-loss recovery

A Dataflow worker VM was deleted mid-stream. Per-minute ingestion into raw:

```
07:02   122   worker deleted
07:03     0   gap
07:04     0   gap
07:05   506   Pub/Sub redelivers the unacknowledged backlog
07:06    59   settled
```

The job never left the Running state. Redeliveries carried the same `event_id`
and were suppressed by deduplication; the state survived because Streaming Engine
holds it off the worker. A gap in ingest rate, no gap in coverage, no manual
intervention.

### Least privilege

`roles/pubsub.subscriber` on the subscription permits pulling messages but not
`pubsub.subscriptions.get`, which Dataflow needs for backlog reporting. It
surfaced as `GETTING_PUBSUB_SUBSCRIPTION_FAILED` in the job log, and was resolved
by adding `roles/pubsub.viewer` in Terraform.

The narrowest role that lets a component do its primary job is not always the
narrowest role it needs.

---

## Analytics

| Query | Question | What makes it non-trivial |
|---|---|---|
| `01_volume_by_satellite.sql` | Which satellites generated the most telemetry? | Raw volume measures how much was *heard*, not how much was *said*. Results are normalised by contact opportunity and both rankings shown, with the difference exposed as `coverage_bias`. |
| `02_battery_voltage_trend.sql` | Battery voltage, with a failure trend | A static average hides a battery falling from 28.5 V to 26.1 V. An OLS slope and days-to-critical projection expose it; a 30-sample floor stops the query fitting a trend to noise. |
| `03_weakest_signal.sql` | Weakest signal, over what window | Mean rather than minimum, with a sample floor and a gaps-and-islands pass that turns bad hours into contiguous windows. Grouping by station separates a weak transmitter from a weak receiver. |
| `04_alerts_and_quarantine.sql` | Alerts by subsystem, and what the count hides | Only answerable by joining quarantine. A `FULL OUTER JOIN` is required because a subsystem whose records are all rejected has no rows in curated at all. |

Query 3 was validated blind against the supplied dataset: it returned SAT-11 at
−98.51 dBm mean against roughly −65 dBm for the other eleven, with 5,328 LOST and
2,894 DEGRADED statuses where the rest recorded none. The dataset's answer key
names SAT-11 as the deliberately degraded satellite. The query found it without
being told what to look for.

---

## Operating

```bash
./scripts/launch_pipeline.sh --status    # active Dataflow jobs
./scripts/launch_pipeline.sh --local     # DirectRunner, for fast iteration
./scripts/launch_pipeline.sh --drain     # graceful stop, in-flight work commits
./scripts/launch_pipeline.sh --cancel    # immediate stop, in-flight state discarded

./scripts/inject_fault.sh drill1         # impossible value  → OUT_OF_BOUNDS
./scripts/inject_fault.sh drill2         # renamed field     → SCHEMA_DRIFT
./scripts/inject_fault.sh drill3 20      # duplicate burst   → 20 raw, 1 curated
```

**Drain versus cancel.** Drain stops ingestion, lets buffered work finish and
commits results — nothing is lost, but you wait. Cancel stops immediately and
discards in-flight state. Drain for planned teardown and version upgrades; cancel
when the job is already broken and being replaced.

Because Pub/Sub retains unacknowledged messages for seven days, cancel-and-relaunch
reprocesses the backlog rather than losing it — which is precisely why
deduplication on a stable key matters. Those two facts connect.

**Rollback.** The pipeline is stateless with respect to its sinks, so rollback is:
drain, relaunch with the previous image tag and `PIPELINE_VERSION`, and seek the
subscription back if reprocessing is needed. The `pipeline_version` column on
every row is what makes this safe — you can identify precisely which rows a bad
version wrote and delete exactly those.

**Teardown.** `terraform destroy` removes the Artifact Registry repository, and
the container image goes with it. The rebuild sequence is therefore destroy →
apply → build → apply. Container images are not Terraform state; in production
the registry would have a lifecycle independent of the environment for exactly
this reason.

---

## Known limitations

Stated plainly, because a README without a candid limitations section reads as
either dishonesty or blindness, and a live review finds out which.

- **Failed BigQuery inserts are not captured into quarantine.** The sink's
  failed-rows output should route there. This is the one hop in the message
  journey with an open loss path.
- **The producer cannot scale horizontally.** It holds orbital state, sequence
  numbers and on-board buffers in process memory and is pinned to a single
  instance. This is not theoretical: when Cloud Run replaced the instance
  mid-run, the producer restarted with a zeroed counter and a freshly randomised
  blackout plan. Sharding by satellite ID range is the fix, and it is the first
  thing that breaks at 100× scale.
- **BigQuery streaming inserts are the next ceiling.** At roughly 100× the row
  rate this approaches per-table quotas and becomes the dominant cost line.
  Moving the sink to the Storage Write API is close to a one-line change and buys
  the most headroom per hour spent.
- **The producer does not flush the Pub/Sub client on SIGTERM.** The client
  batches asynchronously; an instance terminating with unflushed batches loses
  them.
- **Deduplication is bounded and best-effort.** A duplicate arriving beyond the
  60-minute window is not caught. State cost scales with distinct keys × window,
  so this is a sizing trade rather than an oversight. End-to-end exactly-once
  would need idempotency at the sink — `MERGE` on `event_id` — not more state in
  Beam.
- **The clustering justification is architectural, not empirical.** Curated
  currently holds a few thousand rows, well under BigQuery's block size, so a
  bytes-scanned comparison shows no measurable benefit yet. At production volume
  the measurement would be straightforward.
- **The orbital model is deliberately crude** — circular orbits, spherical Earth,
  no J2 perturbation. Coverage gaps emerge from geometry, which is the point.
- **No Cloud Monitoring dashboards.** A stalled producer and a stalled pipeline
  look identical from BigQuery. An alert on the subscription's oldest
  unacked-message age is what distinguishes them.

---

## Further documentation

| Document | Covers |
|---|---|
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Prerequisites, configuration, deployment, verification, rollback, teardown, troubleshooting |
| [`docs/design-rationale.md`](docs/design-rationale.md) | The design-decision answers above in full, plus the 100× scaling analysis and measured evidence |
| [`docs/discovery-answers.md`](docs/discovery-answers.md) | Client answers on plausibility bounds, mandatory fields and the definition of weakest signal — with open assumptions marked **ASSUMED** |
| [`docs/architecture.svg`](docs/architecture.svg) · [`docs/message-journey.svg`](docs/message-journey.svg) | Editable sources for both diagrams |
