# 数据处理

原始信号和派生序列是分开的。改某一段时只改对应文件，Compose 和 Kubernetes 挂的是同一份 `config/`。

## Collector 管道

文件：`config/otel-collector/config.yaml`。校验：

```bash
otelcol-contrib validate --config config/otel-collector/config.yaml --feature-gates service.profilesSupport
```

四个管道：

| 信号 | 处理器顺序 | exporter |
| --- | --- | --- |
| metrics | memory_limiter, attributes/sanitize, filter/query_in_route, transform/business_labels, batch | prometheusremotewrite → `http://prometheus:9090/api/v1/write` |
| logs | memory_limiter, attributes/sanitize, filter/query_in_route, batch | otlphttp/loki → `http://loki:3100/otlp` |
| traces | memory_limiter, attributes/sanitize, filter/query_in_route, tail_sampling, batch | otlp/tempo → `tempo:4317` |
| profiles | memory_limiter | otlp/pyroscope → `pyroscope:4040` |

`memory_limiter` 必须是第一个。`limit_percentage: 75`，`spike_limit_percentage: 20`，每秒检查一次。超限时接收端拒绝数据，指标是 `otelcol_receiver_refused_*`，告警 `CollectorRefusedData`。

`batch` 在 5 秒或 1024 条时发送，上限 2048。profiles 在 Collector 0.161 不能用 batch，所以那条管道没有它。

`attributes/sanitize` 从 traces、metrics、logs 上删除这些键：`user.id`、`order.id`、`customer.id`、`enduser.id`、`http.url`、`http.target`、`url.full`、`url.query`、`url.path`、`http.request.header.cookie`。profiles 处理器列表不支持 attributes，profile 标签要在 SDK 侧控制（demo 只放 `service_name` 和 `deployment_environment`）。

`filter/query_in_route` 丢掉 `http.route` 里带 `?` 的数据点、span 和日志记录。`error_mode: ignore`，表达式不适用于某条数据时跳过，不把整条管道打挂。

`transform/business_labels` 只改业务指标的数据点。不在允许表里的 `channel` 改成 `other`，`method` 改成 `other`，`result` 改成 `failure`，`segment` 改成 `anonymous`。条件里有 `attributes["channel"] != nil`，没有这个属性的其他指标不会被写上 `other`。

`tail_sampling` 只在 traces 管道。`decision_wait: 5s`，`num_traces: 50000`。三条策略是「或」：

1. `status_code` 为 `ERROR` 的全部保留。
2. 延迟超过 500ms 的全部保留。
3. 其余按 `sampling_percentage: 100` 保留。

100 表示这台单机上的 demo 仍能看到成功 trace，只是晚 5 秒。要减量就把 `sampling_percentage` 改小，不要删掉错误策略。见 [data-skew.md](data-skew.md)。

`resource_to_telemetry_conversion.enabled: true` 把资源属性复制成 Prometheus 标签。`service.name` 因此变成 `service_name`。远程写队列 `num_consumers: 4`，`queue_size: 2000`。

Collector 自身指标：`telemetry.metrics.level: detailed`，Prometheus 拉取 `0.0.0.0:8888`。detailed 才会露出 `otelcol_exporter_queue_size` 和 `otelcol_exporter_queue_capacity`。zpages 在 `55679`，健康检查在 `13133`。

## Prometheus 记录规则

文件：`config/prometheus/rules/recording.yml`。评估间隔 30 秒。原始直方图和 counter 仍在，记录规则是给告警和仪表盘用的稳定名字。

| 分组 | 派生什么 | 用的原始指标 |
| --- | --- | --- |
| slo-recording | 错误比率、300ms 内占比、QPS | `http_server_request_duration_seconds_*`，排除 `/healthz` |
| infrastructure-recording | CPU、内存、磁盘剩余比 | `node_*{job="node"}` |
| middleware-recording | Redis 内存比、命令速率、Postgres 连接比、Nginx QPS、Kafka lag | exporter 原始指标 |
| application-recording | 在途请求、进程 CPU | `http_server_active_requests`、`process_runtime_cpython_cpu_utilization_ratio` |
| business-recording | 订单速率、支付成功/失败比（5 分钟和 1 小时）、结账 p95 | `business_*` |
| meta-recording | head series、序列创建速率、Collector 队列占用、Loki/Tempo 丢弃速率 | 各组件自身指标 |

告警读记录规则的例子是 `BusinessPaymentFailureBurn`：短窗口 `business:payments:failure_ratio5m` 和长窗口 `business:payments:failure_ratio1h` 同时超阈值。HTTP SLO 的烧录在 [slo.md](slo.md)。

改完规则后：

```bash
promtool check rules config/prometheus/rules/*.yml
promtool test rules config/prometheus/tests/alerts_test.yml
```

容器里的 Prometheus 要重新加载。Compose 开了 `--web.enable-lifecycle`，可以对 `http://127.0.0.1:9090/-/reload` 发 POST。Kubernetes 上规则在 ConfigMap 里，`subPath` 挂载不会热更新，重启 Prometheus Pod。

## Loki

这份配置没有 Promtail pipeline stages。应用日志是 OTLP，在 Collector 里做属性删除和过滤。Kubernetes 容器日志是 Alloy 的 `loki.source.kubernetes`，没有 `stage` 块，原样推到 `http://loki:3100/loki/api/v1/push`。

要在节点上丢弃或改写日志，加在 `config/alloy/config.k8s.alloy` 的 `loki.source.kubernetes` 和 `loki.write` 之间，用 `loki.process`。不要在 Compose 的 `config.alloy` 里复制一份语义不同的流水线。

Loki 自己的限制在 `config/loki/loki.yaml` 的 `limits_config`：

| 项 | 当前值 | 作用 |
| --- | --- | --- |
| `retention_period` | 168h | 日志保留 7 天。compactor 的 `retention_enabled: true` |
| `ingestion_rate_mb` / `ingestion_burst_size_mb` | 16 / 32 | 租户入口速率 |
| `max_global_streams_per_user` | 10000 | 流数量上限 |
| `max_streams_per_user` | 0 | 0 表示单 ingester 不再单独封顶 |
| `per_stream_rate_limit` / `per_stream_rate_limit_burst` | 5MB / 20MB | 单流速率 |
| `max_label_names_per_series` | 15 | 一条流的标签个数 |
| `max_label_name_length` / `max_label_value_length` | 1024 / 2048 | 标签名和值的长度 |
| `reject_old_samples` | true | 拒绝过旧样本，窗口 `reject_old_samples_max_age: 168h` |

超限后的样本计在 `loki_discarded_samples_total`。

OTLP 资源属性提升为索引标签的列表也在这个文件的 `otlp_config`。多加一个高基数属性（例如 `http.client_ip`）会直接增加流的数量。

## Tempo 和 Pyroscope

Tempo 在 `config/tempo/tempo.yaml`。`-target=all`，本地块。`metrics_generator` 把 span metrics 和 service graph 写回 Prometheus，那是派生指标，原始 trace 仍在 Tempo 块里。块保留用 Tempo 3 的默认 14 天。单二进制没有 backend scheduler，不要在这个文件里单独开 worker 去改 `block_retention`。

Pyroscope 在 `config/pyroscope/config.yaml`。v1 块保留 `compactor_blocks_retention_period: 168h`。入口速率是 `ingestion_rate_mb` 和 `ingestion_burst_size_mb`。

## 保留时间改哪里

| 信号 | 当前 | 改哪里 |
| --- | --- | --- |
| 指标 | 15 天 | Prometheus 参数 `--storage.tsdb.retention.time`，Compose 和 `deploy/kubernetes/base/prometheus.yaml` 各有一份启动参数 |
| 日志 | 7 天 | `config/loki/loki.yaml` 的 `retention_period` |
| 链路 | 14 天（Tempo 3 默认） | 分布式拓扑才用 `backend_worker.compaction.block_retention` |
| Profile | 7 天 | `config/pyroscope/config.yaml` 的 `limits.compactor_blocks_retention_period` |
| 告警状态 | Alertmanager 本地盘 | PVC `alertmanager-data` |

派生记录规则不单独占一份保留。它们是 Prometheus TSDB 里的新序列，跟着 15 天走。
