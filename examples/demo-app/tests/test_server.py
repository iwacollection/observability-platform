import json
import os
import threading
import unittest
import urllib.error
import urllib.request

# Imported after the env var so setup_telemetry stays a no-op.
os.environ["OTEL_ENABLED"] = "false"
os.environ.pop("PYROSCOPE_SERVER_ADDRESS", None)

from demo_app.business import (  # noqa: E402
    BusinessRecorder,
    order_attributes,
    payment_attributes,
    quota_attributes,
    seat_attributes,
)
from demo_app.identity import resolve  # noqa: E402
from demo_app.server import (  # noqa: E402
    TELEMETRY,
    _bounded_float,
    _bounded_int,
    handle_request,
    make_server,
    route_label,
)
from demo_app.telemetry import (  # noqa: E402
    JsonFormatter,
    grpc_target,
    otlp_headers,
    pyroscope_push_settings,
)
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

    def test_health_reports_bounded_tenant(self) -> None:
        status, body = handle_request("GET", "/healthz", {"tenant": ["user-42"], "user_id": ["9"]})
        self.assertEqual(status, 200)
        self.assertEqual(body["business_line"], "toc")
        self.assertEqual(body["tenant"], "consumer")
        self.assertNotIn("user-42", body.values())


class IdentityTests(unittest.TestCase):
    def test_allow_list(self) -> None:
        self.assertEqual(resolve("toc", "user-42", "api")["tenant"], "consumer")
        self.assertEqual(resolve("toc", "acme", "checkout")["org_id"], "toc")
        self.assertEqual(resolve("tob", "acme", "admin")["org_id"], "tob-acme")
        self.assertEqual(resolve("tob", "northwind", "billing")["tenant"], "northwind")
        self.assertEqual(resolve("tob", "northwind", "billing")["org_id"], "tob-northwind")
        rejected = resolve("tob", "user-42", "billing")
        self.assertEqual(rejected["tenant"], "rejected")
        self.assertEqual(rejected["org_id"], "rejected")
        self.assertNotIn("user-42", rejected.values())
        self.assertEqual(resolve("nope", "acme", "admin")["business_line"], "rejected")

    def test_pyroscope_http_url_is_the_per_tenant_path(self) -> None:
        previous = {
            key: os.environ.get(key)
            for key in ("PYROSCOPE_HTTP_URL", "PYROSCOPE_SERVER_ADDRESS", "INGEST_TOKEN")
        }
        try:
            os.environ["PYROSCOPE_HTTP_URL"] = "https://pyroscope.obs.example.invalid:4040"
            os.environ["PYROSCOPE_SERVER_ADDRESS"] = "http://pyroscope:4040"
            os.environ["INGEST_TOKEN"] = "dev-ingest-token"
            settings = pyroscope_push_settings("tob-acme")
            assert settings is not None
            self.assertEqual(settings["server_address"], "https://pyroscope.obs.example.invalid:4040")
            self.assertEqual(settings["tenant_id"], "tob-acme")
            self.assertNotEqual(settings["tenant_id"], "acme")
            self.assertEqual(settings["http_headers"]["Authorization"], "Bearer dev-ingest-token")

            os.environ.pop("PYROSCOPE_HTTP_URL")
            fallback = pyroscope_push_settings("toc")
            assert fallback is not None
            self.assertEqual(fallback["server_address"], "http://pyroscope:4040")
            self.assertEqual(fallback["tenant_id"], "toc")

            os.environ.pop("PYROSCOPE_SERVER_ADDRESS")
            os.environ.pop("INGEST_TOKEN")
            self.assertIsNone(pyroscope_push_settings("toc"))
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_collector_0161_profiles_stay_in_rejected(self) -> None:
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        collector_path = os.path.join(root, "config", "otel-collector", "config.yaml")
        deployment_path = os.path.join(root, "deploy", "kubernetes", "base", "otel-collector.yaml")
        with open(collector_path, encoding="utf-8") as handle:
            text = handle.read()
        with open(deployment_path, encoding="utf-8") as handle:
            deployment = handle.read()
        self.assertIn("otel/opentelemetry-collector-contrib:0.161.0", deployment)
        self.assertNotIn("routing/profiles", text)
        self.assertIn("X-Scope-OrgID: rejected", text)
        profiles = text.split("profiles:", 1)[1].split("# TENANCY:pipelines", 1)[0]
        self.assertIn("exporters: [otlp/pyroscope]", profiles)
        self.assertNotIn("routing/", profiles)

    def test_otlp_headers_follow_the_ingest_token(self) -> None:
        previous = os.environ.pop("INGEST_TOKEN", None)
        try:
            self.assertEqual(otlp_headers(), {})
            os.environ["INGEST_TOKEN"] = "dev-ingest-token"
            self.assertEqual(otlp_headers(), {"authorization": "Bearer dev-ingest-token"})
        finally:
            if previous is None:
                os.environ.pop("INGEST_TOKEN", None)
            else:
                os.environ["INGEST_TOKEN"] = previous

    def test_tob_routes_do_not_take_raw_ids(self) -> None:
        import demo_app.server as server

        previous = server.APP_IDENTITY
        server.APP_IDENTITY = resolve("tob", "user-99", "billing")
        try:
            self.assertEqual(server.APP_IDENTITY["tenant"], "rejected")
            self.assertNotIn("user-99", server.APP_IDENTITY.values())
            server.APP_IDENTITY = resolve("tob", "acme", "billing")
            status, body = handle_request("GET", "/api/invoices", {"fail": ["1"], "customer": ["u-1"]})
            self.assertEqual(status, 200)
            self.assertEqual(body["result"], "failure")
            self.assertNotIn("u-1", body.values())
            self.assertEqual(seat_attributes("custom-plan-999"), {"plan": "other"})
            self.assertEqual(quota_attributes("tenant-acme-user"), {"quota_class": "other"})
            server.APP_IDENTITY = resolve("tob", "northwind", "admin")
            status, body = handle_request("GET", "/api/seats", {"plan": ["enterprise"], "count": ["3"], "limit": ["10"]})
            self.assertEqual(status, 200)
            self.assertEqual(body["plan"], "enterprise")
            status, body = handle_request("GET", "/api/work", {})
            self.assertEqual(status, 404)
        finally:
            server.APP_IDENTITY = previous
