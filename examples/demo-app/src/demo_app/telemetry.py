"""OpenTelemetry wiring shared by the demo server.

Disabled when OTEL_ENABLED is false or 0 so unit tests do not open exporters.
"""

from __future__ import annotations

import json
import logging
import os
import socket
from typing import Any

from opentelemetry import metrics, trace
from opentelemetry.trace import SpanContext

from demo_app.business import BusinessRecorder
from demo_app.identity import resolve_from_env

SERVICE_NAMESPACE = "observability"

# Explicit histogram buckets. 0.3s is the latency SLO boundary.
HTTP_DURATION_BUCKETS = (
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.3,
    0.5,
    1,
    2.5,
    5,
    10,
)
CHECKOUT_DURATION_BUCKETS = (0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)

# Process and runtime only. Host CPU/memory/network stay on node_exporter.
PROCESS_METRIC_CONFIG: dict[str, list[str] | None] = {
    "process.cpu.time": ["user", "system"],
    "process.cpu.utilization": ["user", "system"],
    "process.memory.usage": None,
    "process.memory.virtual": None,
    "process.thread.count": None,
    "process.runtime.memory": ["rss", "vms"],
    "process.runtime.cpu.time": ["user", "system"],
    "process.runtime.cpu.utilization": None,
    "process.runtime.thread_count": None,
    "cpython.gc.collections": None,
}


class JsonFormatter(logging.Formatter):
    """One JSON object per line, including the active trace id when present."""

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if isinstance(ctx, SpanContext) and ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


class _NoopHistogram:
    def record(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None


class _NoopCounter:
    def add(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None


class _NoopGauge:
    def set(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None


class Telemetry:
    def __init__(self, tracer: trace.Tracer, histogram: Any, active: Any, business: Any) -> None:
        self.tracer = tracer
        self.histogram = histogram
        self.active = active
        self.business = business


def telemetry_enabled() -> bool:
    return os.environ.get("OTEL_ENABLED", "true").lower() not in {"0", "false", "no"}


def ingest_token() -> str:
    """Bearer token for the ingest gateway and the collector receiver.

    Empty when unset so unit tests do not invent a credential. Compose and
    the dev overlay set the documented placeholder dev-ingest-token.
    """
    return os.environ.get("INGEST_TOKEN", "").strip()


def otlp_headers() -> dict[str, str]:
    token = ingest_token()
    if not token:
        return {}
    return {"authorization": f"Bearer {token}"}


def grpc_target(raw: str) -> tuple[str, bool]:
    """Return (host:port, insecure) for the OTLP gRPC exporter."""
    value = raw.strip().rstrip("/")
    insecure = True
    for prefix, secure in (("https://", False), ("http://", True)):
        if value.startswith(prefix):
            insecure = secure
            value = value[len(prefix) :]
            break
    return value, insecure


def setup_logging() -> logging.Logger:
    logger = logging.getLogger("demo_app")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    logger.propagate = False
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)
    return logger


def setup_telemetry(logger: logging.Logger, identity: dict[str, str] | None = None) -> Telemetry:
    """Return tracers and instruments. No-ops when telemetry is off."""
    identity = identity or resolve_from_env()
    if not telemetry_enabled():
        return Telemetry(
            trace.get_tracer("demo-app"),
            _NoopHistogram(),
            _NoopCounter(),
            BusinessRecorder(),
        )

    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry._logs import set_logger_provider

    service_name = os.environ.get("OTEL_SERVICE_NAME", "demo-app")
    environment = os.environ.get("DEPLOYMENT_ENVIRONMENT", "local")
    cluster = os.environ.get("CLUSTER_NAME", "local")
    business_line = identity["business_line"]
    tenant = identity["tenant"]
    org_id = identity["org_id"]
    headers = otlp_headers()
    endpoint, insecure = grpc_target(
        os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
    )
    interval_ms = int(os.environ.get("OTEL_METRIC_EXPORT_INTERVAL", "5000"))
    # Trace-based exemplars attach the active span's trace id to histogram
    # samples. Prometheus stores them because exemplar storage is enabled.
    os.environ.setdefault("OTEL_METRICS_EXEMPLAR_FILTER", "trace_based")

    resource = Resource.create(
        {
            "service.name": service_name,
            "service.namespace": SERVICE_NAMESPACE,
            "service.version": os.environ.get("DEMO_VERSION", "0.1.0"),
            "service.instance.id": socket.gethostname(),
            "deployment.environment": environment,
            "cluster": cluster,
            "business_line": business_line,
            "tenant": tenant,
        }
    )

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=insecure, timeout=5, headers=headers))
    )
    try:
        from pyroscope.otel import PyroscopeSpanProcessor

        tracer_provider.add_span_processor(PyroscopeSpanProcessor())
    except Exception as exc:  # optional correlation; profiles still push over HTTP
        logger.warning("pyroscope span processor disabled: %s", exc)
    trace.set_tracer_provider(tracer_provider)

    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=endpoint, insecure=insecure, timeout=5, headers=headers),
        export_interval_millis=interval_ms,
    )
    meter_provider = MeterProvider(
        resource=resource,
        metric_readers=[reader],
        views=[
            View(
                instrument_name="http.server.request.duration",
                aggregation=ExplicitBucketHistogramAggregation(boundaries=HTTP_DURATION_BUCKETS),
            ),
            View(
                instrument_name="business.checkout.duration",
                aggregation=ExplicitBucketHistogramAggregation(boundaries=CHECKOUT_DURATION_BUCKETS),
            ),
        ],
    )
    metrics.set_meter_provider(meter_provider)
    meter = meter_provider.get_meter("demo-app")
    histogram = meter.create_histogram(
        name="http.server.request.duration",
        unit="s",
        description="HTTP server request duration",
    )
    active = meter.create_up_down_counter(
        name="http.server.active_requests",
        unit="{request}",
        description="In-flight HTTP server requests",
    )
    business = BusinessRecorder(
        orders=meter.create_counter(
            name="business.orders.created",
            unit="{order}",
            description="Orders accepted by the demo checkout API",
        ),
        payments=meter.create_counter(
            name="business.payments",
            unit="{payment}",
            description="Payment attempts by result and method",
        ),
        checkout=meter.create_histogram(
            name="business.checkout.duration",
            unit="s",
            description="Checkout handler duration",
        ),
        active_users=meter.create_gauge(
            name="business.users.active",
            unit="{user}",
            description="Active users observed by segment",
        ),
        invoices=meter.create_counter(
            name="business.invoices",
            unit="{invoice}",
            description="ToB invoices by result",
        ),
        seats=meter.create_gauge(
            name="business.seats.active",
            unit="{seat}",
            description="ToB seats in use by plan",
        ),
        seat_limit=meter.create_gauge(
            name="business.seats.limit",
            unit="{seat}",
            description="ToB seat limit by plan",
        ),
        quota_used=meter.create_gauge(
            name="business.api.quota.used",
            unit="{request}",
            description="ToB API quota consumed",
        ),
        quota_limit=meter.create_gauge(
            name="business.api.quota.limit",
            unit="{request}",
            description="ToB API quota limit",
        ),
    )
    _configure_process_metrics(logger)

    log_provider = LoggerProvider(resource=resource)
    log_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=endpoint, insecure=insecure, timeout=5, headers=headers))
    )
    set_logger_provider(log_provider)
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=log_provider)
    otel_handler.setFormatter(JsonFormatter())
    logger.addHandler(otel_handler)

    _configure_pyroscope(logger, service_name, environment, cluster, business_line, tenant, org_id)
    return Telemetry(trace.get_tracer("demo-app"), histogram, active, business)


def _configure_process_metrics(logger: logging.Logger) -> None:
    try:
        from opentelemetry.instrumentation.system_metrics import SystemMetricsInstrumentor

        SystemMetricsInstrumentor(config=PROCESS_METRIC_CONFIG).instrument()
    except Exception as exc:
        logger.warning("process runtime metrics disabled: %s", exc)


def pyroscope_server_address() -> str:
    """Per-tenant profile push address.

    PYROSCOPE_HTTP_URL is the supported variable. It is the same key as
    ConfigMap observability-endpoints. PYROSCOPE_SERVER_ADDRESS remains a
    fallback for an older process environment.
    """
    primary = os.environ.get("PYROSCOPE_HTTP_URL", "").strip()
    if primary:
        return primary
    return os.environ.get("PYROSCOPE_SERVER_ADDRESS", "").strip()


def pyroscope_push_settings(org_id: str) -> dict[str, Any] | None:
    """SDK settings for one org.

    tenant_id is the X-Scope-OrgID (toc, tob-acme, tob-northwind), not the
    tenant label. Collector 0.161.0 cannot set that header per tenant on
    the profiles pipeline, so this HTTP push is the supported path.
    """
    address = pyroscope_server_address()
    if not address:
        return None
    token = ingest_token()
    settings: dict[str, Any] = {
        "server_address": address,
        "tenant_id": org_id,
    }
    if token:
        settings["http_headers"] = {"Authorization": f"Bearer {token}"}
    else:
        settings["http_headers"] = {}
    return settings


def _configure_pyroscope(
    logger: logging.Logger,
    service_name: str,
    environment: str,
    cluster: str,
    business_line: str,
    tenant: str,
    org_id: str,
) -> None:
    settings = pyroscope_push_settings(org_id)
    if settings is None:
        return
    try:
        import pyroscope

        # tenant_id is X-Scope-OrgID (pyroscope-io 1.2.4). http_headers carries
        # the ingest bearer token; the SDK has no separate bearer argument.
        pyroscope.configure(
            application_name=service_name,
            server_address=settings["server_address"],
            tenant_id=settings["tenant_id"],
            http_headers=settings["http_headers"],
            tags={
                "service_name": service_name,
                "deployment_environment": environment,
                "cluster": cluster,
                "business_line": business_line,
                "tenant": tenant,
            },
            enable_logging=False,
        )
    except Exception as exc:
        logger.warning("pyroscope push disabled: %s", exc)
