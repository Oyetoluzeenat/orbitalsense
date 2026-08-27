# Copy and edit for your project. Nothing secret belongs in this file.
project_id = "orbitalsense-fc331b"
region     = "europe-west1"
env        = "dev"

# Set by scripts/deploy_producer.sh; the placeholder lets the first apply run.
producer_image = "europe-west1-docker.pkg.dev/orbitalsense-fc331b/orbitalsense/producer:0.1.1"

# The account that launches Dataflow jobs, e.g. you@example.com
deployer_account = "oyetoluzeenat@gmail.com"

satellite_count = 12
ground_stations = ["GS-1", "GS-2", "GS-3", "GS-4"]
subsystems      = ["power", "thermal", "comms", "orbital"]

raw_retention_days        = 90
curated_retention_days    = 400
quarantine_retention_days = 400

# Sized to cover the 40-minute GS-3 delivery constraint, with margin.
allowed_lateness_minutes = 45
dedup_window_minutes     = 60
pipeline_version         = "1.0.0"

producer_min_instances = 1
emit_interval_seconds  = 2
malformed_rate         = 0.02
duplicate_rate         = 0.03
