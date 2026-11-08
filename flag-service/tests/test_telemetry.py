import importlib.util
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from flask import Flask
import requests
from opentelemetry import trace
from opentelemetry.trace import SpanKind
import telemetry

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
PARENT_ID = "00f067aa0ba902b7"


def test_health_filter_and_unsampled_parent(spans):
    app = Flask(__name__)
    app.add_url_rule("/health", endpoint="health", view_func=lambda: "ok")
    app.add_url_rule("/flags/<name>", endpoint="flag", view_func=lambda name: name)
    telemetry.instrument_flask(app)
    client = app.test_client()
    headers = {"traceparent": f"00-{TRACE_ID}-{PARENT_ID}-00"}
    assert client.get("/health", headers=headers).status_code == 200
    assert client.get("/health?probe=true", headers=headers).status_code == 200
    assert client.get("/flags/health-checkout", headers=headers).status_code == 200
    assert client.get("/flags/checkout?tag=health", headers=headers).status_code == 200
    trace.get_tracer_provider().force_flush()
    servers = [s for s in spans.get_finished_spans() if s.kind == SpanKind.SERVER]
    assert len(servers) == 2
    for span in servers:
        assert span.name == "GET /flags/<name>"
        assert span.context.trace_id == int(TRACE_ID, 16)
        assert span.parent.span_id == int(PARENT_ID, 16)
        assert span.context.trace_flags.sampled


def test_requests_propagates_context(spans):
    headers = []
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            headers.append(self.headers.get("traceparent"))
            self.send_response(200)
            self.end_headers()
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    telemetry.instrument_requests()
    try:
        with trace.get_tracer("test").start_as_current_span("parent") as parent:
            response = requests.get(f"http://127.0.0.1:{server.server_port}/validate", timeout=2)
            assert response.status_code == 200
        trace.get_tracer_provider().force_flush()
        clients = [s for s in spans.get_finished_spans() if s.kind == SpanKind.CLIENT]
        assert len(clients) == 1
        assert clients[0].parent.span_id == parent.context.span_id
        assert headers[0].split("-")[1] == f"{parent.context.trace_id:032x}"
        assert headers[0].split("-")[2] == f"{clients[0].context.span_id:016x}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)


def test_gunicorn_stops_consumer_before_telemetry(monkeypatch):
    calls = []
    app = SimpleNamespace(stop_worker=lambda timeout: calls.append("stop") or True)
    sdk = SimpleNamespace(shutdown_telemetry=lambda timeout_seconds: calls.append("flush"))
    monkeypatch.setitem(sys.modules, "app", app)
    monkeypatch.setitem(sys.modules, "telemetry", sdk)
    path = Path(__file__).resolve().parents[1] / "gunicorn.conf.py"
    spec = importlib.util.spec_from_file_location("test_gunicorn_config", path)
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    config.worker_exit(None, SimpleNamespace(log=SimpleNamespace(warning=lambda *args: None)))
    assert calls == ["stop", "flush"]


def test_telemetry_shutdown_has_total_deadline():
    import time
    path = Path(telemetry.__file__)
    spec = importlib.util.spec_from_file_location("isolated_shutdown_telemetry", path)
    isolated = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(isolated)
    release = threading.Event()
    entered = [threading.Event(), threading.Event()]
    class Provider:
        def __init__(self, event):
            self.event = event
        def shutdown(self):
            self.event.set()
            release.wait(2)
    isolated._providers = [Provider(event) for event in entered]
    started = time.monotonic()
    try:
        isolated.shutdown_telemetry(timeout_seconds=0.05)
        assert time.monotonic() - started < 1
        assert all(event.is_set() for event in entered)
    finally:
        release.set()
