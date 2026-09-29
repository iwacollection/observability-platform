import json
import os
import threading
import unittest
import urllib.error
import urllib.request

# Imported after the env var so setup_telemetry stays a no-op.
os.environ["OTEL_ENABLED"] = "false"
os.environ.pop("PYROSCOPE_SERVER_ADDRESS", None)

from demo_app.business import BusinessRecorder, order_attributes, payment_attributes  # noqa: E402
from demo_app.server import (  # noqa: E402
    TELEMETRY,
    _bounded_float,
    _bounded_int,
    handle_request,
    make_server,
    route_label,
)
from demo_app.telemetry import JsonFormatter, grpc_target  # noqa: E402
from opentelemetry import trace  # noqa: E402
from opentelemetry.sdk.trace import TracerProvider  # noqa: E402


class ImportTests(unittest.TestCase):
    def test_exporter_modules_import(self) -> None:
        from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
        from pyroscope.otel import PyroscopeSpanProcessor

        self.assertTrue(callable(OTLPLogExporter))
        self.assertTrue(callable(PyroscopeSpanProcessor))


class HandlerTests(unittest.TestCase):
    def test_routes(self) -> None:
        status, body = handle_request("GET", "/healthz", {})
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

        status, body = handle_request("GET", "/api/work", {"burn_ms": ["1"]})
        self.assertEqual(status, 200)
        self.assertIn("checksum", body)

        status, body = handle_request("GET", "/api/error", {})
        self.assertEqual(status, 500)

        status, body = handle_request("GET", "/api/slow", {"seconds": ["0"]})
        self.assertEqual(status, 200)
        self.assertEqual(body["slept"], 0.0)

        status, _ = handle_request("POST", "/api/work", {})
        self.assertEqual(status, 405)

        status, _ = handle_request("GET", "/missing", {})
        self.assertEqual(status, 404)

    def test_business_label_allow_list(self) -> None:
        self.assertEqual(order_attributes("web"), {"channel": "web"})
        self.assertEqual(order_attributes("user-42"), {"channel": "other"})
        self.assertEqual(payment_attributes("wire", True), {"method": "other", "result": "failure"})
        self.assertEqual(payment_attributes("card", False), {"method": "card", "result": "success"})
        self.assertEqual(route_label("/api/orders"), "/api/orders")
        self.assertEqual(route_label("/api/orders/12345"), "other")

        class Fake:
            def __init__(self) -> None:
                self.calls: list[tuple] = []

            def add(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("add", amount, attributes))

            def record(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("record", amount, attributes))

            def set(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("set", amount, attributes))

        orders, payments, checkout, active = Fake(), Fake(), Fake(), Fake()
        recorder = BusinessRecorder(orders, payments, checkout, active)
        self.assertEqual(recorder.order_created("api")["channel"], "api")
        self.assertEqual(orders.calls, [("add", 1, {"channel": "api"})])
        recorded = recorder.payment("wallet", True, 0.2)
        self.assertEqual(recorded["result"], "failure")
        self.assertEqual(payments.calls[0][2]["method"], "wallet")
        self.assertEqual(checkout.calls[0][0], "record")
        self.assertEqual(checkout.calls[0][2], {"result": "failure"})
        self.assertEqual(recorder.note_active("nope")["segment"], "anonymous")
        self.assertEqual(active.calls[0][2], {"segment": "anonymous"})

    def test_query_bounds(self) -> None:
        self.assertEqual(_bounded_float({"seconds": ["99"]}, "seconds", 0.8, 5.0), 5.0)
        self.assertEqual(_bounded_float({"seconds": ["nope"]}, "seconds", 0.8, 5.0), 0.8)
        self.assertEqual(_bounded_int({"burn_ms": ["9000"]}, "burn_ms", 40, 2000), 2000)
        _, body = handle_request("GET", "/api/slow", {"seconds": ["0"]})
        self.assertEqual(body["slept"], 0.0)

    def test_grpc_target(self) -> None:
        self.assertEqual(grpc_target("http://otel-collector:4317"), ("otel-collector:4317", True))
        self.assertEqual(grpc_target("https://otel.example:4317"), ("otel.example:4317", False))


class JsonLogTests(unittest.TestCase):
    def test_trace_id_present_inside_span(self) -> None:
        import logging

        trace.set_tracer_provider(TracerProvider())
        tracer = trace.get_tracer("test")
        formatter = JsonFormatter()
        record_holder = {}

        logger = logging.getLogger("demo_app.test")
        logger.handlers.clear()
        logger.propagate = False

        class ListHandler(logging.Handler):
            def emit(self, record: logging.LogRecord) -> None:
                record_holder["line"] = formatter.format(record)

        logger.addHandler(ListHandler())
        with tracer.start_as_current_span("unit"):
            logger.info("hello")
        payload = json.loads(record_holder["line"])
        self.assertEqual(payload["msg"], "hello")
        self.assertEqual(len(payload["trace_id"]), 32)
        self.assertEqual(len(payload["span_id"]), 16)


class ServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = make_server("127.0.0.1", 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def _get(self, path: str) -> tuple[int, dict]:
        try:
            with urllib.request.urlopen(self.base + path, timeout=3) as response:
                return response.status, json.loads(response.read().decode())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read().decode())

    def test_http(self) -> None:
        status, body = self._get("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "demo-app")
        status, body = self._get("/api/error")
        self.assertEqual(status, 500)
        self.assertEqual(body["error"], "forced failure")

    def test_business_http(self) -> None:
        class Fake:
            def __init__(self) -> None:
                self.calls: list[tuple] = []

            def add(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("add", amount, attributes))

            def record(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("record", amount, attributes))

            def set(self, amount: float, attributes: dict | None = None) -> None:
                self.calls.append(("set", amount, attributes))

        orders, payments, checkout, active = Fake(), Fake(), Fake(), Fake()
        TELEMETRY.business = BusinessRecorder(orders, payments, checkout, active)
        status, body = self._get("/api/orders?channel=user-99")
        self.assertEqual(status, 200)
        self.assertEqual(body["channel"], "other")
        self.assertEqual(orders.calls[0][2], {"channel": "other"})
        status, body = self._get("/api/checkout?method=card&fail=1&segment=authenticated&delay_ms=0")
        self.assertEqual(status, 200)
        self.assertEqual(body["result"], "failure")
        self.assertEqual(body["method"], "card")
        self.assertEqual(body["segment"], "authenticated")
        self.assertEqual(payments.calls[0][2], {"method": "card", "result": "failure"})
        self.assertEqual(active.calls[0][2], {"segment": "authenticated"})
        self.assertGreaterEqual(checkout.calls[0][1], 0.0)
