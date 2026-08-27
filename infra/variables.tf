variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "Single region for every regional resource. Do not mix regions."
  default     = "europe-west1"
}

variable "env" {
  type        = string
  description = "Environment suffix used in every resource name."
  default     = "dev"
}

# ---------------------------------------------------------------------------
# Constellation parameters. Issued at kickoff, not fixed in code.
# ---------------------------------------------------------------------------

variable "satellite_count" {
  type        = number
  description = "Number of simulated satellites."
  default     = 12
}

variable "ground_stations" {
  type        = list(string)
  description = "Ground station identifiers."
  default     = ["GS-1", "GS-2", "GS-3", "GS-4"]
}

variable "subsystems" {
  type        = list(string)
  description = "Subsystems each satellite reports on."
  default     = ["power", "thermal", "comms", "orbital"]
}

# ---------------------------------------------------------------------------
# Retention. Section 3.4 requires this to be justified, so make it a knob.
# ---------------------------------------------------------------------------

variable "raw_retention_days" {
  type        = number
  description = "Raw telemetry retention. Exists for replay and proof of receipt."
  default     = 90
}

variable "curated_retention_days" {
  type        = number
  description = "Curated telemetry retention."
  default     = 400
}

variable "quarantine_retention_days" {
  type        = number
  description = "Quarantine retention. Outlives raw: investigations start late."
  default     = 400
}

# ---------------------------------------------------------------------------
# Pipeline behaviour. A constraint revealed mid-project should cost one line.
# ---------------------------------------------------------------------------

variable "allowed_lateness_minutes" {
  type        = number
  description = "Windowing lateness allowance. Sized to cover the GS-3 delay."
  default     = 45
}

variable "dedup_window_minutes" {
  type        = number
  description = "Deduplication state window, in processing time."
  default     = 60
}

variable "pipeline_version" {
  type        = string
  description = "Stamped on every row. This is what makes rollback safe."
  default     = "1.0.0"
}

# ---------------------------------------------------------------------------
# Producer
# ---------------------------------------------------------------------------

variable "producer_image" {
  type        = string
  description = "Fully qualified Artifact Registry image for the producer."
}

variable "producer_min_instances" {
  type        = number
  description = "Set to 1 only when continuous telemetry is actually needed."
  default     = 0
}

variable "emit_interval_seconds" {
  type        = number
  description = "Seconds between producer emission ticks."
  default     = 2
}

variable "malformed_rate" {
  type        = number
  description = "Fraction of messages deliberately corrupted."
  default     = 0.02
}

variable "duplicate_rate" {
  type        = number
  description = "Fraction of messages deliberately re-sent with the same event_id."
  default     = 0.03
}

variable "deployer_account" {
  type        = string
  description = "Human account that launches Dataflow jobs; granted serviceAccountUser on the pipeline SA."
}
