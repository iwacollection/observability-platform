# 指标目录

五层指标都落在同一套 Prometheus 上。应用和业务指标由 Collector 远程写入，名字按 OpenTelemetry Collector 0.161 的 Prometheus 翻译规则生成：点改下划线，单位 `s` 变成 `_seconds`，单调 counter 加 `_total`，单位为 `1` 的 gauge 加 `_ratio`，花括号单位（例如 `{order}`）不追加后缀。

数据源 UID 固定为 `prometheus`。下面的「仪表盘」列是 Grafana UID，打开路径是 `/d/<uid>`。

## 1. 基础监控

来源：`prom/node-exporter:v1.9.1`，Prometheus job `node`，目标 `node-exporter:9100`。Alloy 的 unix exporter 另写一份，job 是 `alloy-unix`，仪表盘和告警不用它，避免把同一台机器算两次。Kubernetes 上 cAdvisor 由 `config/alloy/config.k8s.alloy` 抓取，job `cadvisor`。对象健康由 kube-state-metrics v2.16.0 提供，job `kube-state-metrics`，只在 Kubernetes 上由 Alloy 远程写入。

| 指标 | 类型 | 标签 | 来源 | 示例 PromQL | 告警 | 仪表盘 |
| --- | --- | --- | --- | --- | --- | --- |
| `up{job="node"}` | gauge | job, instance | node_exporter | `up{job="node"}` | NodeDown | infrastructure |
| `node_cpu_seconds_total` | counter | job, instance, cpu, mode | node_exporter | `instance:node_cpu_utilization:ratio` | NodeCPUSaturation | infrastructure, host, overview |
| `node_memory_MemAvailable_bytes` / `node_memory_MemTotal_bytes` | gauge | job, instance | node_exporter | `instance:node_memory_utilization:ratio` | NodeMemorySaturation | infrastructure |
| `node_filesystem_avail_bytes` / `node_filesystem_size_bytes` | gauge | job, instance, mountpoint, fstype, device | node_exporter | `instance:node_filesystem_free:ratio` | DiskSpaceLow, NodeDiskWillFill | infrastructure, host |
| `node_load1` | gauge | job, instance | node_exporter | `node_load1{job="node"}` | NodeLoadHigh | infrastructure, host |
| `node_disk_io_time_seconds_total` | counter | job, instance, device | node_exporter | `rate(node_disk_io_time_seconds_total{job="node"}[5m])` | — | infrastructure |
| `node_network_receive_bytes_total` / `node_network_transmit_bytes_total` | counter | job, instance, device | node_exporter | `rate(node_network_receive_bytes_total{job="node",device!="lo"}[5m])` | — | infrastructure, host |
| `container_cpu_usage_seconds_total` | counter | namespace, pod, container | cAdvisor，仅 Kubernetes | `rate(container_cpu_usage_seconds_total{container!=""}[5m])` | — | infrastructure, host |
| `container_memory_working_set_bytes` | gauge | namespace, pod, container | cAdvisor，仅 Kubernetes | `container_memory_working_set_bytes{container!=""}` | — | infrastructure, host |
| `kube_pod_status_ready` | gauge | job, namespace, pod, condition | kube-state-metrics | `kube_pod_status_ready{job="kube-state-metrics",condition="false"}` | KubePodNotReady | infrastructure |
| `kube_deployment_status_replicas_unavailable` | gauge | job, namespace, deployment | kube-state-metrics | `kube_deployment_status_replicas_unavailable{job="kube-state-metrics"}` | KubeDeploymentUnavailable | infrastructure |

记录规则在 `config/prometheus/rules/recording.yml` 的 `infrastructure-recording`：`instance:node_cpu_utilization:ratio`、`instance:node_memory_utilization:ratio`、`instance:node_filesystem_free:ratio`。

## 2. 中间件监控

这些进程是平台的监控对象，不是另一套产品。Compose 和 Kubernetes 使用相同的 Service 名，所以 `config/prometheus/prometheus.yml` 里的静态目标两边都能解析。

| 指标 | 类型 | 标签 | 来源 | 示例 PromQL | 告警 | 仪表盘 |
| --- | --- | --- | --- | --- | --- | --- |
| `redis_up` | gauge | job, instance | redis_exporter v1.74.0，`redis-exporter:9121` | `redis_up` | RedisDown | middleware |
| `redis_memory_used_bytes` / `redis_memory_max_bytes` | gauge | job, instance | redis_exporter。`maxmemory 64mb` 写在 `config/redis/redis.conf` | `redis:memory_utilization:ratio` | RedisMemorySaturation | middleware |
| `redis_commands_processed_total` | counter | job, instance | redis_exporter | `redis:commands:rate5m` | — | middleware |
| `redis_rejected_connections_total` | counter | job, instance | redis_exporter | `rate(redis_rejected_connections_total[5m])` | RedisRejectedConnections | middleware |
| `pg_up` | gauge | job, instance | postgres_exporter v0.17.1，`postgres-exporter:9187` | `pg_up` | PostgresDown | middleware |
| `pg_stat_database_numbackends` | gauge | datid, datname | postgres_exporter，`stat_database` 默认开启 | `postgres:connections:ratio` | PostgresConnectionSaturation | middleware |
| `pg_settings_max_connections` | gauge | server 等 exporter 常量标签 | postgres_exporter 的 pg_settings 采集 | `max(pg_settings_max_connections)` | PostgresConnectionSaturation | middleware |
| `pg_stat_database_xact_commit` / `pg_stat_database_xact_rollback` | counter | datid, datname | postgres_exporter | `rate(pg_stat_database_xact_rollback[5m])` | PostgresRollbackRatio | middleware |
| `pg_stat_database_blks_hit` / `pg_stat_database_blks_read` | counter | datid, datname | postgres_exporter | `rate(pg_stat_database_blks_hit[5m])` | — | — |
| `pg_stat_database_deadlocks` | counter | datid, datname | postgres_exporter | `rate(pg_stat_database_deadlocks[5m])` | — | — |
| `nginx_up` | gauge | job, instance | nginx-prometheus-exporter 1.4.2，`nginx-exporter:9113` | `nginx_up` | NginxDown | middleware |
| `nginx_http_requests_total` | counter | job, instance | nginx stub_status，见 `config/nginx/nginx.conf` | `nginx:requests:rate5m` | — | middleware |
| `nginx_connections_active` / `nginx_connections_accepted` / `nginx_connections_handled` | gauge 或 counter | job, instance | stub_status 没有状态码。错误比率看应用 RED | `rate(nginx_connections_accepted[5m]) - rate(nginx_connections_handled[5m])` | NginxDroppedConnections | middleware |
| `kafka_brokers` | gauge | job, instance | kafka_exporter v1.9.0，`kafka-exporter:9308` | `kafka_brokers` | KafkaNoBrokers | middleware |
| `kafka_consumergroup_lag` | gauge | consumergroup, topic, partition | kafka_exporter | `kafka:consumergroup_lag:sum` | KafkaConsumerLagHigh | middleware |

stub_status 不提供 5xx。Nginx 这一层用 USE：`nginx_up`、连接是否被处理、请求速率。HTTP 错误比率在应用层。

## 3. 应用监控

来源：`examples/demo-app` 的 OTel SDK，经 Collector `prometheusremotewrite` 写入。资源属性 `service.name` 变成标签 `service_name`。直方图 `http.server.request.duration` 的桶写在 `examples/demo-app/src/demo_app/telemetry.py` 的 `HTTP_DURATION_BUCKETS`，包含 SLO 用的 `0.3`。

`http.route` 只允许 `KNOWN_ROUTES` 里的路径，其余记成 `other`。`/healthz` 仍会导出，但 SLO 和 `HighErrorRate` 把它排除。

Exemplar：进程设置 `OTEL_METRICS_EXEMPLAR_FILTER=trace_based`，`histogram.record` 发生在当前 span 内。Prometheus 启动参数有 `--enable-feature=exemplar-storage`。Grafana Prometheus 数据源把 exemplar 的 `trace_id` 指到 Tempo UID `tempo`。

| 指标 | 类型 | 标签 | 来源 | 示例 PromQL | 告警 | 仪表盘 |
| --- | --- | --- | --- | --- | --- | --- |
| `http_server_request_duration_seconds_count` | histogram count | service_name, http_route, http_request_method, http_response_status_code | demo-app | `sum(rate(http_server_request_duration_seconds_count{http_route!="/healthz"}[5m]))` | HighErrorRate | application, demo-app, overview |
| `http_server_request_duration_seconds_bucket` | histogram bucket | 同上，加 le | demo-app | `histogram_quantile(0.95, sum by (service_name, le) (rate(..._bucket{http_route!="/healthz"}[5m])))` | HighLatency, SLOLatencyFastBurn | application |
| `http_server_active_requests` | gauge（UpDownCounter） | service_name, http_route, http_request_method | demo-app | `service:http_inflight:sum` | AppInFlightSaturation | application |
| `process_runtime_cpython_cpu_utilization_ratio` | gauge | service_name | system-metrics 0.66b0，单位 `1` | `service:process_cpu_utilization:ratio` | AppProcessCPUSaturation | application |
| `process_runtime_cpython_memory_bytes` | gauge | service_name, type（rss 或 vms） | system-metrics，单位 `By` | `process_runtime_cpython_memory_bytes{type="rss"}` | — | application |
| `process_runtime_cpython_cpu_time_seconds_total` | counter | service_name, type | system-metrics | `rate(process_runtime_cpython_cpu_time_seconds_total[5m])` | — | — |
| `process_cpu_time_seconds_total` | counter | service_name, type | system-metrics `process.cpu.time` | `rate(process_cpu_time_seconds_total[5m])` | — | — |
| `process_memory_usage_bytes` | gauge | service_name | system-metrics | `process_memory_usage_bytes` | — | — |
| `slo:http_errors:ratio_rate5m` 及 30m、1h、6h、1d、3d | recording | service_name | `recording.yml` | `slo:http_errors:ratio_rate5m` | SLOAvailabilityFastBurn, SLOAvailabilitySlowBurn | application |
| `slo:http_latency_good:ratio_rate5m` 及 1h、6h | recording | service_name | `recording.yml`，`le="0.3"` | `slo:http_latency_good:ratio_rate5m` | SLOLatencyFastBurn | application |

## 4. 业务监控

仪器在 `examples/demo-app/src/demo_app/business.py`。未知取值收成固定桶，不丢点，这样分母还在。

| 允许的标签 | 允许的值 |
| --- | --- |
| `channel`（订单） | `web`、`api`、`other` |
| `method`（支付） | `card`、`wallet`、`other` |
| `result`（支付、结账） | `success`、`failure` |
| `segment`（活跃用户） | `anonymous`、`authenticated` |

禁止作为业务标签的键：`user.id`、`order.id`、`customer.id`、`enduser.id`，以及任何订单号、用户号、URL。Collector 的 `attributes/sanitize` 会删这些键；`transform/business_labels` 会把不在表里的业务取值改写掉。

| 指标 | 类型 | 标签 | OTel 名 | 示例 PromQL | 告警 | 仪表盘 |
| --- | --- | --- | --- | --- | --- | --- |
| `business_orders_created_total` | counter | service_name, channel | `business.orders.created`，单位 `{order}` | `business:orders:created:rate5m` | — | business |
| `business_payments_total` | counter | service_name, method, result | `business.payments`，单位 `{payment}` | `sum by (service_name) (rate(business_payments_total{result="failure"}[5m])) / sum by (service_name) (rate(business_payments_total[5m]))` | BusinessPaymentFailureRatio | business |
| `business_checkout_duration_seconds_bucket` | histogram | service_name, result, le | `business.checkout.duration`，单位 `s`，桶见 `CHECKOUT_DURATION_BUCKETS` | `business:checkout_duration:p95_5m` | — | business |
| `business_users_active` | gauge | service_name, segment | `business.users.active`，单位 `{user}` | `business_users_active` | — | business |
| `business:payments:success_ratio5m` | recording | service_name | 由 payments counter 派生 | `business:payments:success_ratio5m` | — | business |
| `business:payments:failure_ratio5m` / `failure_ratio1h` | recording | service_name | 双窗口 | `business:payments:failure_ratio5m > 0.2 and business:payments:failure_ratio1h > 0.1` | BusinessPaymentFailureBurn | business |

支付失败在 demo 里仍返回 HTTP 200。`/api/error` 才是 HTTP 500。这样业务失败比率不会和 RED 错误比率混成一个数。

路由：

| 路径 | 行为 |
| --- | --- |
| `GET /api/orders?channel=web\|api` | 记一笔订单。其他 channel 记成 `other` |
| `GET /api/checkout?method=card\|wallet&fail=0\|1&segment=anonymous\|authenticated&delay_ms=0` | 记支付结果、结账延迟、活跃用户。`delay_ms` 最大 2000 |

## 5. 可观测性自身监控

Prometheus 直接抓这些进程的 `/metrics`。Collector 自身指标在 `otel-collector:8888`（本机 `127.0.0.1:8888`），`telemetry.metrics.level` 是 `detailed`，所以队列长度和容量会出来。

| 指标 | 类型 | 标签 | 来源 | 示例 PromQL | 告警 | 仪表盘 |
| --- | --- | --- | --- | --- | --- | --- |
| `up` | gauge | job, instance | 每个 scrape job | `up == 0` | TargetDown；GrafanaDown；AlertmanagerDown | meta |
| `otelcol_receiver_accepted_spans_total` | counter | receiver, transport | Collector 0.161。旧名不带 `_total` 的序列告警里用 `or` 兼容 | `sum(rate(otelcol_receiver_accepted_spans_total[5m]))` | — | meta |
| `otelcol_receiver_refused_spans_total` 及 metric points、log records | counter | receiver | Collector，内存限制或接收端拒绝 | `sum(rate(otelcol_receiver_refused_spans_total[5m]))` | CollectorRefusedData | meta |
| `otelcol_processor_dropped_spans_total` 及 metric points、log records | counter | processor | Collector | 同上 | CollectorRefusedData | meta |
| `otelcol_exporter_send_failed_spans_total` 及 metric points、log records | counter | exporter | Collector | `sum(rate(otelcol_exporter_send_failed_spans_total[5m]))` | CollectorExportFailures | meta, overview |
| `otelcol_exporter_sent_spans_total` 及 metric points、log records | counter | exporter | Collector | `sum(rate(otelcol_exporter_sent_spans_total[5m]))` | — | meta |
| `otelcol_exporter_queue_size` / `otelcol_exporter_queue_capacity` | gauge | exporter | Collector detailed，单位是 batch | `platform:collector_queue_utilization:ratio` | CollectorExporterQueueNearFull | meta |
| `prometheus_tsdb_head_series` | gauge | — | Prometheus v3.15.0 | `platform:prometheus_head_series` | PrometheusHighSeries（> 200000） | meta |
| `prometheus_tsdb_head_series_created_total` | counter | — | Prometheus | `platform:prometheus_series_created:rate10m` | PrometheusSeriesChurn（> 50/s） | meta |
| `prometheus_rule_evaluation_failures_total` | counter | rule_group | Prometheus | `sum(rate(prometheus_rule_evaluation_failures_total[5m]))` | PrometheusRuleEvalFailures | meta |
| `prometheus_rule_group_iterations_missed_total` | counter | rule_group | Prometheus | `rate(prometheus_rule_group_iterations_missed_total[5m])` | — | — |
| `loki_distributor_lines_received_total` | counter | tenant 等 | Loki 3.7.8 | `sum(rate(loki_distributor_lines_received_total[5m]))` | — | meta |
| `loki_distributor_bytes_received_total` | counter | tenant | Loki | `sum(rate(loki_distributor_bytes_received_total[5m]))` | — | — |
| `loki_discarded_samples_total` | counter | reason, tenant | Loki | `platform:loki_discarded_samples:rate5m` | LokiSamplesDiscarded | meta |
| `loki_ingester_memory_streams` | gauge | tenant | Loki | `sum(loki_ingester_memory_streams)` | — | meta |
| `loki_ingester_streams_created_total` | counter | tenant | Loki | `sum(rate(loki_ingester_streams_created_total[10m]))` | LokiStreamChurn（> 50/s） | meta |
| `tempo_distributor_spans_received_total` | counter | tenant | Tempo 3.0.3 | `sum(rate(tempo_distributor_spans_received_total[5m]))` | — | meta |
| `tempo_distributor_bytes_received_total` | counter | tenant | Tempo | `sum(rate(tempo_distributor_bytes_received_total[5m]))` | — | — |
| `tempo_discarded_spans_total` | counter | reason, tenant | Tempo。reason 含 `rate_limited`、`trace_too_large`、`live_traces_exceeded` | `platform:tempo_discarded_spans:rate5m` | TempoSpansDiscarded | meta |
| `pyroscope_distributor_profiles_received_total` | counter | tenant, scope | Pyroscope 2.3.1 | `sum(rate(pyroscope_distributor_profiles_received_total[5m]))` | — | meta |
| `pyroscope_distributor_received_compressed_bytes_count` | histogram count | tenant | Pyroscope | `sum(rate(pyroscope_distributor_received_compressed_bytes_count[5m]))` | — | — |
| `pyroscope_discarded_samples_total` / `pyroscope_discarded_bytes_total` | counter | reason, tenant | Pyroscope | `sum by (reason) (rate(pyroscope_discarded_samples_total[5m]))` | PyroscopeSamplesDiscarded | meta |
| `prometheus_remote_storage_samples_failed_total` | counter | job=`alloy` | Alloy v1.20.1 的 `prometheus.remote_write` | `sum(rate(prometheus_remote_storage_samples_failed_total{job="alloy"}[5m]))` | AlloyRemoteWriteFailures | meta |
| `up{job="grafana"}` / `up{job="alertmanager"}` | gauge | job, instance | Grafana `:3000`，Alertmanager `:9093` | `up{job="grafana"}` | GrafanaDown, AlertmanagerDown | meta |

抓取失败除了 `up == 0`，还可以看目标页上的 `prometheus_target_scrapes_exceeded_body_size_limit_total` 和 `prometheus_target_scrapes_sample_out_of_bounds_total`。本仓库没有为这两条单独写告警，它们出现在 Prometheus `job="prometheus"` 的 `/metrics` 里，用来对照「为什么 head series 在涨」。
