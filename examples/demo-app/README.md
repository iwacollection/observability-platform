# demo-app

一个用 Python 标准库实现的 HTTP 服务，用来给可观测性平台灌数据。

- `GET /healthz` 与 `GET /` 返回 200，不计入 SLO
- `GET /api/work` 做一小段 CPU 计算，便于 Pyroscope 看到栈
- `GET /api/slow?seconds=0.8` 人为拉高延迟
- `GET /api/error` 返回 500

指标、日志、链路通过 OTLP 发到 Collector。Profile 通过 Pyroscope 的 HTTP ingest 推到 `PYROSCOPE_SERVER_ADDRESS`。接入约定写在仓库根目录 README 的「应用接入」一节。
