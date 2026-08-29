# OrbitalSense — Deployment Guide

## 1. Prerequisites

| Requirement | Version used | Notes |
|---|---|---|
| gcloud | 581.0.0 | `gcloud auth login` **and** `gcloud auth application-default login` |
| Terraform | 1.9.8 | pinned in `.terraform-version` |
| Docker | 29.7.2 | or Cloud Build as an alternative — see §4 |
| Python | 3.11 | Beam's GCP extras are fussy about newer versions |
| Region | europe-west1 | chosen once; every regional resource uses it |

IAM on the deploying human: project editor plus `roles/iam.serviceAccountUser`
on the pipeline service account. The latter is created by Terraform from
`var.deployer_account`. `roles/owner` is not required.

No service account keys are used anywhere. Application Default Credentials and
impersonation cover every path, which is why there is no secret in this
repository to leak.

Billing must be linked before the first apply, and a budget alert should be set:
a streaming Dataflow job bills continuously and is by a wide margin the largest
cost in this system.

```bash
export PROJECT_ID="orbitalsense-fc331b"
export REGION="europe-west1"
export ENV="dev"
```

## 2. Bootstrap the state bucket (once per project)

```bash
make bootstrap
```

Equivalent to:

```bash
cd infra/bootstrap && terraform init && \
  terraform apply -var="project_id=$PROJECT_ID" -var="region=$REGION"
```

Creates `${PROJECT_ID}-tfstate` with object versioning enabled. This is a
separate root module because a backend cannot create the bucket it stores its
own state in. It is still Terraform, and it is not a violation of the
no-manual-provisioning rule.

## 3. Initialise the main module

```bash
make init
```

Equivalent to:

```bash
cd infra && terraform init -reconfigure \
  -backend-config="bucket=${PROJECT_ID}-tfstate" \
  -backend-config="prefix=orbitalsense/${ENV}"
```

A backend block cannot use variables, which is why the bucket is passed at init.

## 4. Configuration

Edit `infra/envs/dev.tfvars`. At minimum set `project_id`, `producer_image`
and `deployer_account`.

| Variable | Default | Change it when |
|---|---|---|
| `satellite_count` | 12 | The client issues a different constellation size |
| `ground_stations` | GS-1 … GS-4 | The station list changes |
| `subsystems` | power, thermal, comms, orbital | The subsystem list changes |
| `allowed_lateness_minutes` | 45 | A delivery-delay constraint is revealed |
| `dedup_window_minutes` | 60 | Memory pressure, or a longer redelivery envelope |
| `raw_retention_days` | 90 | The client answers the retention question |
| `curated_retention_days` | 400 | Longer analytical history is required |
| `producer_min_instances` | 0 | Continuous telemetry is needed — set to 1 |
| `malformed_rate` / `duplicate_rate` | 0.02 / 0.03 | The corruption profile changes |
| `pipeline_version` | 1.0.0 | Every deployment; this is what makes rollback safe |

## 5. Deploy

```bash
./scripts/deploy_producer.sh 0.1.1   # build, push, apply
./scripts/launch_pipeline.sh         # launch the Dataflow job
./scripts/inject_fault.sh start      # begin telemetry
```

If local Docker cannot reach Artifact Registry, build remotely instead — same
Dockerfile, no local networking involved:

```bash
gcloud builds submit producer/ \
  --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/orbitalsense/producer:0.1.1
cd infra && terraform apply -var-file=envs/dev.tfvars
```

## 6. Verify

```bash
./scripts/inject_fault.sh stats        # producer counters, blackout plan
./scripts/inject_fault.sh verify       # reconciliation
./scripts/inject_fault.sh quarantine   # rejection breakdown
```

Reconciliation: `raw = curated + quarantined + duplicates suppressed`. If those
numbers do not add up, one hop is losing data.

Expected within a few minutes: `published` climbing, non-zero `corrupted` and
`duplicated`, `buffered` growing whenever satellites are over ocean, and six or
more distinct `reason_code` values in quarantine.

## 7. Operate

```bash
./scripts/launch_pipeline.sh --status
./scripts/launch_pipeline.sh --local     # DirectRunner, for fast iteration
./scripts/inject_fault.sh drill1         # impossible value  -> OUT_OF_BOUNDS
./scripts/inject_fault.sh drill2         # renamed field     -> SCHEMA_DRIFT
./scripts/inject_fault.sh drill3 20      # duplicate burst   -> 20 raw, 1 curated
```

**Replay.** Pub/Sub retains seven days with `retain_acked_messages` on:

```bash
gcloud pubsub subscriptions seek orbitalsense-pipeline-dev \
  --time="2026-08-27T09:00:00Z"
```

**Drain versus cancel.** Drain stops ingestion, lets buffered work finish and
commits results — nothing lost, but you wait. Cancel stops immediately and
discards in-flight state. Drain for planned teardown and version upgrades;
cancel when the job is already broken and being replaced. Because Pub/Sub
retains unacknowledged messages, cancel-and-relaunch reprocesses the backlog
rather than losing it — which is precisely why deduplication keyed on a stable
`event_id` matters. Those two facts connect.

## 8. Rollback

The pipeline is stateless with respect to its sinks and Pub/Sub holds seven days:

1. `./scripts/launch_pipeline.sh --drain`
2. Relaunch with the previous image tag and `PIPELINE_VERSION` set accordingly.
3. Seek the subscription back if reprocessing is needed.

The `pipeline_version` column on every row is what makes this safe: you can
identify precisely which rows a bad version wrote and delete exactly those. This
system currently holds rows from three versions — `1.0.0-dev`, `1.1.0-dedup`
and `1.2.0-dataflow` — and they are individually filterable.

## 9. Teardown

Order matters.

```bash
# 1. Stop new data at the source
./scripts/inject_fault.sh stop

# 2. Drain the pipeline so in-flight windows commit
./scripts/launch_pipeline.sh --drain
gcloud dataflow jobs list --region=$REGION --status=active   # wait for empty

# 3. Tear down infrastructure
cd infra && terraform destroy -var-file=envs/dev.tfvars

# 4. State bucket last, and only if genuinely finished
cd bootstrap && terraform destroy \
  -var="project_id=$PROJECT_ID" -var="region=$REGION"
```

Destroying while a Dataflow job still holds the subscription will hang.

### Full destroy and rebuild

`terraform destroy` removes the Artifact Registry repository, and the producer
image goes with it. The rebuild sequence is three steps, not two:

```bash
make destroy
gcloud builds submit producer/ \
  --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/orbitalsense/producer:0.1.1
make apply
```

Container images are not Terraform state. In production the registry would have
a lifecycle independent of the environment for exactly this reason.

Measured on this system: destroy of 38 resources ~2 minutes; apply ~4 minutes,
of which 60 seconds is the deliberate API-propagation wait in `apis.tf`.

## 10. Daily shutdown

A streaming Dataflow job bills until stopped.

```bash
./scripts/inject_fault.sh stop
./scripts/launch_pipeline.sh --cancel
./scripts/launch_pipeline.sh --status    # confirm nothing running
```

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error 403: API has not been used` | API enablement race | `time_sleep` in `apis.tf` |
| `bucket is not empty` on destroy | Objects present | `force_destroy = true` on working buckets |
| Destroy hangs on the subscription | Dataflow job attached | Drain or cancel first |
| Cloud Run: `Image not found` | Registry destroyed with the environment | Rebuild before apply — see §9 |
| Cloud Run: startup probe fails | Import error in `main.py` | `gcloud logging read` for the traceback |
| `GETTING_PUBSUB_SUBSCRIPTION_FAILED` | `subscriber` alone is insufficient | `roles/pubsub.viewer` — in `iam.tf` |
| Works on DirectRunner, fails on Dataflow | Modules not shipped | `--setup_file=./pipeline/setup.py` |
| `Missing required option: project` | Beam's own options unset | `opts.view_as(GoogleCloudOptions).project` |
| `Cannot query over table without a filter` | `require_partition_filter` on raw | Add the `ingest_time` filter |

## Known local issue (WSL2 development machines)

WSL2 in this environment resolves Google API endpoints to IPv6 addresses but has
no IPv6 route. Go-based tools (Terraform, gcloud) dial IPv6 and fail with
"cannot assign requested address". Workaround: pin IPv4 addresses for Google
endpoints in `/etc/hosts`. This is a developer-machine networking issue, not a
property of the deployed platform.
