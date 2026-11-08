"""Lifecycle dos workers; não usar --preload (SDKs e clientes por processo)."""
import sys

graceful_timeout = 35


def post_worker_init(worker):
    app = sys.modules.get("app")
    if app is not None and hasattr(app, "start_worker"):
        app.start_worker()


def worker_exit(server, worker):
    app = sys.modules.get("app")
    if app is not None and hasattr(app, "stop_worker"):
        if not app.stop_worker(timeout=20):
            worker.log.warning("Consumidor não encerrou no prazo; mensagens pendentes podem ser reentregues")
    telemetry = sys.modules.get("telemetry")
    if telemetry is not None:
        telemetry.shutdown_telemetry(timeout_seconds=5)
