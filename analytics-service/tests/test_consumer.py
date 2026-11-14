import importlib
import json
import threading
from unittest.mock import Mock

import pytest
from botocore.stub import Stubber
from opentelemetry import trace
from opentelemetry.trace import SpanKind, StatusCode


@pytest.fixture
def app(monkeypatch, otel):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("AWS_SQS_URL", "https://sqs.us-east-1.amazonaws.com/123456789012/events")
    monkeypatch.setenv("AWS_DYNAMODB_TABLE", "test-events")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test-only")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test-only")
    monkeypatch.setenv("AWS_EC2_METADATA_DISABLED", "true")
    module = importlib.import_module("app")
    yield module
    assert module.stop_worker(timeout=2)


def test_consumer_continues_trace_and_records_exception(app, spans):
    parent_trace = "4bf92f3577b34da6a3ce929d0e0e4736"
    parent_span = "00f067aa0ba902b7"
    message = {"MessageId": "test-message", "ReceiptHandle": "test-receipt", "Body": json.dumps(
        {"user_id": "u1", "flag_name": "f1", "result": True, "timestamp": "2026-11-07T00:00:00Z"}),
        "MessageAttributes": {"traceparent": {"DataType": "String", "StringValue": f"00-{parent_trace}-{parent_span}-00"}}}
    assert app._worker_thread is None or not app._worker_thread.is_alive()  # Importar a aplicação não inicia o consumidor.
    with Stubber(app.dynamodb_client) as dynamodb, Stubber(app.sqs_client) as sqs:
        dynamodb.add_response("put_item", {})
        sqs.add_response("delete_message", {})
        app.handle_message(message)
    app.handle_message(dict(message, Body="invalid-json"))
    trace.get_tracer_provider().force_flush()
    consumers = [s for s in spans.get_finished_spans() if s.kind == SpanKind.CONSUMER]
    assert len(consumers) == 2
    good, bad = consumers
    assert good.context.trace_id == int(parent_trace, 16)
    assert good.parent.span_id == int(parent_span, 16)
    assert good.context.trace_flags.sampled
    children = [s for s in spans.get_finished_spans() if s.parent and s.parent.span_id == good.context.span_id]
    assert {s.attributes.get("rpc.method") for s in children} == {"PutItem", "DeleteMessage"}
    assert bad.status.status_code == StatusCode.ERROR
    assert any(event.name == "exception" for event in bad.events)


def test_stop_drains_current_message_without_starting_next(app, monkeypatch):
    entered, release, stopping, stopped = (threading.Event() for _ in range(4))
    first, second = {"MessageId": "first"}, {"MessageId": "second"}
    client = Mock()
    client.receive_message.return_value = {"Messages": [first, second]}
    monkeypatch.setattr(app, "sqs_client", client)
    processed = []
    def process(message):
        processed.append(message)
        entered.set()
        assert release.wait(2)
    monkeypatch.setattr(app, "handle_message", process)
    original_set = app._worker_stop.set
    def stop_signal():
        original_set()
        stopping.set()
    monkeypatch.setattr(app._worker_stop, "set", stop_signal)
    result = []
    def stop():
        result.append(app.stop_worker(timeout=2))
        stopped.set()
    app.start_worker()
    assert entered.wait(2)
    thread = threading.Thread(target=stop)
    thread.start()
    try:
        assert stopping.wait(2)
        assert not stopped.is_set()
    finally:
        release.set()
        thread.join(3)
    assert result == [True]
    assert processed == [first]
    assert client.receive_message.call_count == 1
