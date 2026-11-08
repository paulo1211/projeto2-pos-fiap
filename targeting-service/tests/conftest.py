import sys
from pathlib import Path
from unittest.mock import patch

import pytest
from opentelemetry import trace
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import telemetry


@pytest.fixture(scope="session", autouse=True)
def otel():
    exporter = InMemorySpanExporter()
    reader = InMemoryMetricReader()
    with patch.object(telemetry, "OTLPSpanExporter", return_value=exporter), \
         patch.object(telemetry, "PeriodicExportingMetricReader", return_value=reader):
        telemetry.setup_telemetry("test-service")
    yield exporter, reader
    telemetry.shutdown_telemetry()


@pytest.fixture
def spans(otel):
    exporter, _ = otel
    trace.get_tracer_provider().force_flush()
    exporter.clear()
    yield exporter
    trace.get_tracer_provider().force_flush()
