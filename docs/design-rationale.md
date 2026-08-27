## Deduplication: measured, not asserted

Before (pipeline_version 1.0.0-dev):
  21 events duplicated on the wire  →  42 rows in curated

After (pipeline_version 1.1.0-dedup):
  N events duplicated on the wire   →  N rows in curated

Raw retains all copies in both cases, deliberately: a repeat delivery is a fact
about the world, and raw's job is to record what arrived.