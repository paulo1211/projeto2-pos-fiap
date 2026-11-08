"""SIGTERM real: drenar mensagem em andamento antes do flush OTel."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest


def wait_until(check, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.02)
    raise AssertionError("Condição não atingida dentro do prazo")


def test_sigterm_drains_message_and_exports_consumer_span(tmp_path):
    requests = []

    class Receiver(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.path == "/v1/traces":
                requests.append(ExportTraceServiceRequest.FromString(body))
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass

    receiver = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    server_thread = threading.Thread(target=receiver.serve_forever, daemon=True)
    server_thread.start()
    # Fake AWS apenas neste subprocesso. A aplicação, SDKs, gunicorn e OTLP são reais.
    (tmp_path / "sitecustomize.py").write_text('''
import json, os, time
from pathlib import Path
import boto3
directory = Path(os.environ["TEST_LIFECYCLE_DIR"])
class Client:
    received = False
    def receive_message(self, **kwargs):
        if self.received:
            time.sleep(0.05)
            return {}
        self.received = True
        return {"Messages": [{"MessageId": "message-1", "ReceiptHandle": "receipt-1", "Body": json.dumps(
            {"user_id":"u1", "flag_name":"f1", "result":True, "timestamp":"2026-11-07T00:00:00Z"})}]}
    def put_item(self, **kwargs):
        (directory / "entered").touch()
        deadline = time.monotonic() + 15
        while not (directory / "release").exists():
            if time.monotonic() > deadline:
                raise TimeoutError("Teste não liberou a mensagem")
            time.sleep(0.02)
        return {}
    def delete_message(self, **kwargs):
        (directory / "deleted").touch()
        return {}
class Session:
    def __init__(self, **kwargs): pass
    def client(self, service, **kwargs): return Client()
boto3.Session = Session
''')
    service = Path(__file__).resolve().parents[1]
    env = dict(os.environ)
    env.update({
        "PYTHONPATH": str(tmp_path),
        "TEST_LIFECYCLE_DIR": str(tmp_path),
        "AWS_REGION": "us-east-1",
        "AWS_SQS_URL": "https://sqs.us-east-1.amazonaws.com/123456789012/events",
        "AWS_DYNAMODB_TABLE": "test-events",
        "AWS_EC2_METADATA_DISABLED": "true",
        "OTEL_SDK_DISABLED": "false",
        "OTEL_EXPORTER_OTLP_ENDPOINT": f"http://127.0.0.1:{receiver.server_port}",
        "OTEL_BSP_SCHEDULE_DELAY": "60000",
    })
    process = None
    logfile = tmp_path / "gunicorn.log"
    try:
        with logfile.open("w") as output:
            process = subprocess.Popen(
                [sys.executable, "-m", "gunicorn", "--config", "gunicorn.conf.py",
                 "--bind", "127.0.0.1:0", "app:app"],
                cwd=service, env=env, stdout=output, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            wait_until(lambda: (tmp_path / "entered").exists())
            process.terminate()
            wait_until(lambda: "Worker exiting" in logfile.read_text())
            # O hook começou, mas deve continuar aguardando a mensagem.
            assert process.poll() is None
            assert not (tmp_path / "deleted").exists()
            (tmp_path / "release").touch()
            assert process.wait(timeout=10) == 0, logfile.read_text()
        assert (tmp_path / "deleted").exists()
        spans = [s for request in requests for resource in request.resource_spans
                 for scope in resource.scope_spans for s in scope.spans]
        assert any(s.kind == 5 and s.name == "events process" for s in spans), logfile.read_text()
    finally:
        (tmp_path / "release").touch()
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        receiver.shutdown()
        receiver.server_close()
        server_thread.join(2)
