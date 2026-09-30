# demo-app

一个用 Python 标准库实现的 HTTP 服务，用来给可观测性平台灌数据。

- `GET /healthz` 与 `GET /` 返回 200，不计入 SLO
- `GET /api/work` 做一小段 CPU 计算，便于 Pyroscope 看到栈
- `GET /api/slow?seconds=0.8` 人为拉高延迟
- `GET /api/error` 返回 500
- `GET /api/orders?channel=web|api` 记订单。其他 channel 收成 `other`
- `GET /api/checkout?method=card|wallet&fail=0|1&segment=anonymous|authenticated&delay_ms=0` 记支付、结账延迟和活跃用户。支付失败仍是 HTTP 200

指标、日志、链路通过 OTLP 发到 Collector。直方图带 trace exemplar（`OTEL_METRICS_EXEMPLAR_FILTER=trace_based`）。进程运行时指标来自 `opentelemetry-instrumentation-system-metrics`，不采集主机 CPU。Profile 通过 Pyroscope 的 HTTP ingest 推到 `PYROSCOPE_HTTP_URL`，`tenant_id` 是 org id。

业务标签只允许 `channel`、`method`、`result`、`segment`，取值见 `src/demo_app/business.py`。Collector 里的 `transform/business_labels` 做同样的收口。接入约定在仓库根目录 README 和 `docs/onboarding.md`。
