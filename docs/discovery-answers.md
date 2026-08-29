# Discovery Answers

Section 6.4 of the specification withholds several details deliberately: they
are only obtainable by asking during a scheduled discovery conversation. This
file records what was asked, what was answered, when, and by whom.

**Anything marked ASSUMED is running on our own default, not a client answer.**
A marked assumption is risk management. An unmarked one discovered by a reviewer
is carelessness.

---

## Validation

**Q1. Plausibility bounds per field. Constellation-wide or per satellite?**
Status: **ASSUMED** — defaults in `pipeline/validation.py`.
Answered by: — Date: —

| Field | Plausible | Nominal |
|---|---|---|
| `battery_voltage_v` | 18.0 – 36.0 | 26.0 – 30.0 |
| `solar_array_current_a` | 0.0 – 30.0 | 0.5 – 12.0 |
| `temperature_c` | -80 – 150 | -20 – 55 |
| `signal_strength_dbm` | -140 – -20 | -105 – -60 |
| `bit_error_rate` | 0.0 – 1.0 | 0 – 1e-4 |
| `altitude_km` | 300 – 2000 | 500 – 600 |
| `latitude_deg` | -90 – 90 | n/a |
| `longitude_deg` | -180 – 180 | n/a |

**Q2. Which fields are mandatory versus optional? Does it vary by subsystem?**
Status: **ASSUMED** — `event_id`, `satellite_id`, `subsystem`, `event_time`
mandatory; `sequence` and `producer_version` optional; metric fields mandatory
for their own subsystem and absent otherwise.

**Q3. A message with one bad metric out of three: reject entirely, or accept
with that metric nulled?**
Status: **ASSUMED** — reject the whole record. This materially changes the
pipeline and should have been asked early.

**Q4. An unrecognised metric field: quarantine, ignore, or store and flag?**
Status: **ASSUMED** — quarantine as `SCHEMA_DRIFT`. Silently ignoring is how a
renamed field becomes an invisible outage. Verified in practice: a `signalStrength`
field was correctly rejected with the offending field recorded.

## Alerting

**Q5. What defines "trending toward failure" for battery voltage?**
Status: **ASSUMED** — OLS slope below -0.20 V/day with projected time-to-critical
under 30 days, requiring at least 30 samples.

**Q6. Is there a nominal band distinct from the plausible band?**
Status: **ASSUMED** — yes, and the distinction is load-bearing. 9,999 V is
corrupt and quarantined; 24.1 V is a real alert and curated.

## Analytics

**Q7. Precise definition of "weakest communication signal".**
Status: **ASSUMED** — lowest mean `signal_strength_dbm` over a contiguous run of
hourly buckets, at least 20 samples per bucket, reported per satellite and per
satellite-station pair. Mean rather than minimum: a single deep fade during
handover is not a weak link; a sustained low mean is.

**Q8. Telemetry volume: raw, or normalised by contact opportunity?**
Status: **ASSUMED** — both are reported, with the rank difference exposed as
`coverage_bias`.

## Operational

**Q9. Raw telemetry retention, and is there a regulatory driver?**
Status: **ASSUMED** — 90 days, Nearline at 30.

**Q10. Expected maximum delivery lateness per ground station?**
Status: **ASSUMED** — 40 minutes for GS-3; `allowed_lateness_minutes` set to 45.

**Q11. Is timeliness measured from event time or receipt at the station?**
Status: **ASSUMED** — event time, the stricter reading.

**Q12. Who consumes quarantine data, and how quickly?**
Status: **OPEN**.

## Scale

**Q13. Planned constellation growth over the next four quarters?**
Status: **OPEN**. See design rationale for the 100x analysis.

**Q14. Is exactly-once required for billing or compliance, or is at-least-once
with best-effort deduplication acceptable?**
Status: **ASSUMED** — at-least-once with best-effort deduplication. If this
changes, the sink changes, not the pipeline.
