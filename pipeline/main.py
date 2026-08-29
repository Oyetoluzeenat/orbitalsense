import argparse
import logging

import apache_beam as beam
from apache_beam.io.gcp.bigquery import BigQueryDisposition, WriteToBigQuery
from apache_beam.metrics import Metrics
from apache_beam.options.pipeline_options import (
    GoogleCloudOptions, PipelineOptions, StandardOptions)
from apache_beam.transforms.deduplicate import DeduplicatePerKey
from apache_beam.transforms.trigger import (
    AccumulationMode, AfterProcessingTime, AfterWatermark)
from apache_beam.transforms.window import FixedWindows, TimestampedValue
from apache_beam.utils.timestamp import Duration

import validation
from transforms import QUARANTINE, RAW, ProcessTelemetry, dedup_key


class CountOut(beam.DoFn):
    """A dedup step whose in and out counts are always equal is not deduplicating."""

    def __init__(self, name):
        self.counter = Metrics.counter("dedup", name)

    def process(self, element):
        self.counter.inc()
        yield element


def to_timestamped(record):
    et = validation.parse_event_time(record["event_time"])
    return TimestampedValue(record, et.timestamp())


def run(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--pipeline_version", default="1.0.0")
    parser.add_argument("--allowed_lateness_minutes", type=int, default=45)
    parser.add_argument("--dedup_window_minutes", type=int, default=60)
    parser.add_argument("--window_seconds", type=int, default=60)
    known, beam_args = parser.parse_known_args(argv)

    opts = PipelineOptions(beam_args, save_main_session=True)
    opts.view_as(StandardOptions).streaming = True
    opts.view_as(GoogleCloudOptions).project = known.project

    def table(name):
        return f"{known.project}:{known.dataset}.{name}"

    common = dict(
        create_disposition=BigQueryDisposition.CREATE_NEVER,   # Terraform owns schemas
        write_disposition=BigQueryDisposition.WRITE_APPEND,
        insert_retry_strategy="RETRY_ON_TRANSIENT_ERROR",
    )

    with beam.Pipeline(options=opts) as p:
        outputs = (
            p
            | "ReadPubSub" >> beam.io.ReadFromPubSub(
                subscription=known.subscription,
                with_attributes=True)
            | "Process" >> beam.ParDo(
                ProcessTelemetry(known.pipeline_version,
                                 known.allowed_lateness_minutes * 60)
              ).with_outputs(RAW, QUARANTINE, main="curated")
        )

        # Raw is deliberately NOT deduplicated: if the same bytes arrived
        # twice, that is a fact about the world and raw should say so.
        outputs[RAW] | "WriteRaw" >> WriteToBigQuery(
            table("raw_telemetry"), **common)

        outputs[QUARANTINE] | "WriteQuarantine" >> WriteToBigQuery(
            table("quarantine_telemetry"), **common)

        deduped = (
            outputs["curated"]
            | "KeyByEventId" >> beam.Map(lambda r: (dedup_key(r), r))
            | "Dedup" >> DeduplicatePerKey(
                  processing_time_duration=Duration(
                      seconds=known.dedup_window_minutes * 60))
            | "Unkey" >> beam.Values()
            | "CountDeduped" >> beam.ParDo(CountOut("records_out"))
        )

        windowed = (
            deduped
            | "AssignEventTime" >> beam.Map(to_timestamped)
            | "Window" >> beam.WindowInto(
                  FixedWindows(known.window_seconds),
                  trigger=AfterWatermark(
                      early=AfterProcessingTime(30),
                      late=AfterProcessingTime(60)),
                  allowed_lateness=known.allowed_lateness_minutes * 60,
                  accumulation_mode=AccumulationMode.ACCUMULATING)
        )

        windowed | "WriteCurated" >> WriteToBigQuery(
            table("curated_telemetry"), **common)


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()