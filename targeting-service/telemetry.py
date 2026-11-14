"""Inicialização do OpenTelemetry (traces + métricas) para os serviços Flask.

A telemetria sai por OTLP/HTTP para o OTel Collector gateway, que roteia
traces para o New Relic e para o connector spanmetrics, e métricas para o
Prometheus. Os logs continuam em stdout (coletados pelo otel-agent via
filelog), agora com trace_id/span_id em cada linha para correlação.

Configuração 100% por variáveis de ambiente padrão do OTel:
  OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES,
  OTEL_EXPORTER_OTLP_ENDPOINT (ex.: http://otel-gateway.observability:4318),
  OTEL_SDK_DISABLED=true desliga tudo (uso local sem Collector).

Este arquivo é idêntico em flag-service, targeting-service e
analytics-service (cada serviço tem seu próprio contexto de build Docker).
"""
import atexit
import logging
import os
import threading
import time

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ALWAYS_ON

LOG_FORMAT = (
    "%(asctime)s %(levelname)s [%(name)s] "
    "[trace_id=%(otelTraceID)s span_id=%(otelSpanID)s] %(message)s"
)


_providers = []
_shutdown_lock = threading.Lock()
_shutdown_started = False
_configured = False


def shutdown_telemetry(timeout_seconds=5):
    """Drena os SDKs em paralelo, com limite total mesmo se o backend falhar."""
    global _shutdown_started
    with _shutdown_lock:
        if _shutdown_started:
            return
        _shutdown_started = True
    deadline = time.monotonic() + timeout_seconds

    def shutdown_provider(provider):
        try:
            provider.shutdown()
        except Exception:
            logging.getLogger(__name__).exception("Falha ao encerrar provider OTel")

    threads = [threading.Thread(target=shutdown_provider, args=(provider,), daemon=True)
               for provider in _providers]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(max(0, deadline - time.monotonic()))
    if any(thread.is_alive() for thread in threads):
        logging.getLogger(__name__).warning("Prazo de encerramento OTel esgotado; pode haver telemetria pendente")


def _enabled():
    return os.getenv("OTEL_SDK_DISABLED", "false").strip().lower() != "true"


def setup_telemetry(default_service_name):
    """Configura providers globais e logging com correlação de trace.

    Deve ser chamada antes de criar clientes instrumentados (pool do
    psycopg2) e antes de qualquer logging.basicConfig da aplicação.
    """
    global _configured
    if _configured:
        return
    _configured = True
    # Injeta otelTraceID/otelSpanID em todo LogRecord (mesmo com o SDK
    # desligado os campos existem, com valor 0), e configura o formato.
    LoggingInstrumentor().instrument(set_logging_format=False)
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)

    if not _enabled():
        logging.getLogger(__name__).info("OpenTelemetry desabilitado (OTEL_SDK_DISABLED=true).")
        return

    # Resource.create lê OTEL_RESOURCE_ATTRIBUTES; OTEL_SERVICE_NAME tem
    # prioridade sobre o nome padrão do serviço.
    resource = Resource.create(
        {SERVICE_NAME: os.getenv("OTEL_SERVICE_NAME", default_service_name)}
    )

    # As métricas RED dependem de todos os spans, inclusive parent sampled=00.
    tracer_provider = TracerProvider(resource=resource, sampler=ALWAYS_ON, shutdown_on_exit=False)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    reader = PeriodicExportingMetricReader(OTLPMetricExporter())
    meter_provider = MeterProvider(resource=resource, metric_readers=[reader], shutdown_on_exit=False)
    metrics.set_meter_provider(meter_provider)
    _providers.extend([tracer_provider, meter_provider])
    atexit.register(shutdown_telemetry)


def instrument_flask(app):
    """Instrumenta o app Flask, ignorando o /health das probes do Kubernetes."""
    if not _enabled():
        return
    from opentelemetry.instrumentation.flask import FlaskInstrumentor

    FlaskInstrumentor().instrument_app(app, excluded_urls=r"^https?://[^/]+/health(?:\?.*)?$")


def instrument_requests():
    if not _enabled():
        return
    from opentelemetry.instrumentation.requests import RequestsInstrumentor

    RequestsInstrumentor().instrument()


def instrument_psycopg2():
    """Spans das queries SQL.

    Atenção: só são rastreados cursores criados com o cursor_factory da
    CONEXÃO (passado ao pool); conn.cursor(cursor_factory=...) por chamada
    não é instrumentado.
    """
    if not _enabled():
        return
    from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

    # skip_dep_check: o instrumentador declara dependência do pacote
    # "psycopg2", mas os serviços usam "psycopg2-binary" (mesmo módulo).
    # Sem isso ele não instrumenta nada e só loga um DependencyConflict.
    Psycopg2Instrumentor().instrument(enable_commenter=False, skip_dep_check=True)


def instrument_botocore():
    if not _enabled():
        return
    from opentelemetry.instrumentation.botocore import BotocoreInstrumentor

    BotocoreInstrumentor().instrument()
