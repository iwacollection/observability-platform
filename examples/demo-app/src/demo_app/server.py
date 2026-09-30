"""HTTP demo with a healthy route, a working route, a slow route, and a 500."""

from __future__ import annotations

import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from opentelemetry.trace import Status, StatusCode

from demo_app.identity import resolve_from_env
from demo_app.telemetry import setup_logging, setup_telemetry

LOGGER = setup_logging()
APP_IDENTITY = resolve_from_env()
TELEMETRY = setup_telemetry(LOGGER, APP_IDENTITY)

# Paths that may appear as the http.route label. Anything else is "other"
# so a scan of random URLs cannot create a series per path.
KNOWN_ROUTES = {
    "/",
    "/healthz",
    "/api/work",
    "/api/slow",
    "/api/error",
    "/api/orders",
    "/api/checkout",
    "/api/invoices",
    "/api/seats",
    "/api/quota",
}

_ROLE_PATHS = {
    "api": {"/", "/healthz", "/api/work", "/api/slow", "/api/error", "/api/orders", "/api/checkout"},
    "checkout": {"/", "/healthz", "/api/orders", "/api/checkout"},
    "admin": {"/", "/healthz", "/api/seats", "/api/quota"},
    "billing": {"/", "/healthz", "/api/invoices"},
}


def burn_cpu(milliseconds: int) -> int:
    """Busy-loop so CPU profiles have a stable stack under this function."""
    deadline = time.perf_counter() + (milliseconds / 1000)
    value = 0
    while time.perf_counter() < deadline:
        value = (value * 33 + 1) % 1_000_003
    return value


def route_label(path: str) -> str:
    return path if path in KNOWN_ROUTES else "other"


def _first(query: dict[str, list[str]], key: str, default: str = "") -> str:
    values = query.get(key)
    if not values:
        return default
    return values[0]


def service_name() -> str:
    return os.environ.get("OTEL_SERVICE_NAME", "demo-app")


def handle_request(method: str, path: str, query: dict[str, list[str]]) -> tuple[int, dict]:
    if method != "GET":
        return 405, {"error": "method not allowed", "method": method}

    identity = APP_IDENTITY
    allowed = _ROLE_PATHS.get(identity["role"], _ROLE_PATHS["api"])
    if path not in allowed and path not in {"/", "/healthz"}:
        return 404, {"error": "not found", "route": path}

    if path in {"/", "/healthz"}:
        return 200, {
            "status": "ok",
            "service": service_name(),
            "business_line": identity["business_line"],
            "tenant": identity["tenant"],
        }

    if path == "/api/work":
        burned = burn_cpu(_bounded_int(query, "burn_ms", default=40, upper=2000))
        return 200, {"status": "ok", "route": path, "checksum": burned}

    if path == "/api/slow":
        delay = _bounded_float(query, "seconds", default=0.8, upper=5.0)
        time.sleep(delay)
        return 200, {"status": "ok", "route": path, "slept": delay}

    if path == "/api/error":
        return 500, {"status": "error", "route": path, "error": "forced failure"}

    if path == "/api/orders":
        if method != "GET":
            return 405, {"error": "method not allowed", "method": method}
        attributes = TELEMETRY.business.order_created(_first(query, "channel", "web"))
        return 200, {"status": "ok", "route": path, "channel": attributes["channel"]}

    if path == "/api/checkout":
        if method != "GET":
            return 405, {"error": "method not allowed", "method": method}
        failed = _first(query, "fail", "0") in {"1", "true", "yes"}
        delay = _bounded_float(query, "delay_ms", default=10, upper=2000) / 1000
        time.sleep(delay)
        segment = TELEMETRY.business.note_active(_first(query, "segment", "anonymous"))
        attributes = TELEMETRY.business.payment(_first(query, "method", "card"), failed, delay)
        # Payment failure stays HTTP 200. The business counter records result.
        # HTTP 5xx remains /api/error so RED and business ratios are separate.
        return 200, {
            "status": "error" if failed else "ok",
            "route": path,
            "result": attributes["result"],
            "method": attributes["method"],
            "segment": segment["segment"],
            "slept": delay,
        }

    if path == "/api/invoices":
        failed = _first(query, "fail", "0") in {"1", "true", "yes"}
        attributes = TELEMETRY.business.invoice(failed)
        return 200, {"status": "ok" if not failed else "error", "route": path, "result": attributes["result"]}

    if path == "/api/seats":
        count = _bounded_float(query, "count", default=1, upper=100000)
        limit = _bounded_float(query, "limit", default=100, upper=1000000)
        attributes = TELEMETRY.business.note_seats(_first(query, "plan", "standard"), count, limit)
        return 200, {
            "status": "ok",
            "route": path,
            "plan": attributes["plan"],
            "count": count,
            "limit": limit,
        }

    if path == "/api/quota":
        used = _bounded_float(query, "used", default=0, upper=1000000)
        limit = _bounded_float(query, "limit", default=1000, upper=1000000)
        attributes = TELEMETRY.business.note_quota(_first(query, "class", "standard"), used, limit)
        return 200, {
            "status": "ok",
            "route": path,
            "quota_class": attributes["quota_class"],
            "used": used,
            "limit": limit,
        }

    return 404, {"error": "not found", "route": path}


def _bounded_int(query: dict[str, list[str]], key: str, default: int, upper: int) -> int:
    raw = query.get(key, [str(default)])[0]
    try:
        value = int(raw)
    except ValueError:
        value = default
    return max(0, min(value, upper))


def _bounded_float(query: dict[str, list[str]], key: str, default: float, upper: float) -> float:
    raw = query.get(key, [str(default)])[0]
    try:
        value = float(raw)
    except ValueError:
        value = default
    return max(0.0, min(value, upper))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler name
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def log_message(self, fmt: str, *args) -> None:
        # Access logs go through the structured logger inside _dispatch.
        return

    def _dispatch(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path or "/"
        query = parse_qs(parsed.query)
        metric_route = route_label(route)
        start = time.perf_counter()
        status = 500
        body: dict = {"status": "error", "route": route, "error": "internal error"}
        duration = 0.0
        attributes = {
            "http.request.method": self.command,
            "http.route": metric_route,
        }
        TELEMETRY.active.add(1, attributes)
        try:
            with TELEMETRY.tracer.start_as_current_span(metric_route) as span:
                span.set_attribute("http.request.method", self.command)
                span.set_attribute("http.route", metric_route)
                try:
                    status, body = handle_request(self.command, route, query)
                except Exception:
                    LOGGER.exception("request failed", extra={})
                    status = 500
                    body = {"status": "error", "route": route, "error": "internal error"}
                    span.set_status(Status(StatusCode.ERROR))
                span.set_attribute("http.response.status_code", status)
                if status >= 500:
                    span.set_status(Status(StatusCode.ERROR, "server error"))
                duration = time.perf_counter() - start
                # record() runs inside the span so the SDK can attach a trace exemplar.
                TELEMETRY.histogram.record(
                    duration,
                    attributes={
                        "http.request.method": self.command,
                        "http.response.status_code": status,
                        "http.route": metric_route,
                    },
                )
            if route != "/healthz":
                LOGGER.log(
                    logging.ERROR if status >= 500 else logging.INFO,
                    "request method=%s route=%s status=%s duration_s=%.4f",
                    self.command,
                    route,
                    status,
                    duration,
                )
            payload = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        finally:
            TELEMETRY.active.add(-1, attributes)


def make_server(host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), Handler)


def main() -> None:
    raw = os.environ.get("DEMO_LISTEN_ADDR", "0.0.0.0:8080")
    host, _, port_text = raw.rpartition(":")
    host = host or "0.0.0.0"
    port = int(port_text or "8080")
    server = make_server(host, port)
    LOGGER.info("listening addr=%s:%s", host, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
