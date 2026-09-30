# 排查

下面的端口、服务名和指标名都是这个仓库里实际挂出来的。本机发布端口绑在 `127.0.0.1`。没有 Docker 守护进程时，先跑 `make config-check`，不要假设栈已经起来。

常用入口：

| 做什么 | 地址 |
| --- | --- |
| Grafana | http://127.0.0.1:3000 |
| Prometheus 查询 / 目标 / 规则 | http://127.0.0.1:9090 |
| Alertmanager | http://127.0.0.1:9093 |
| Loki | http://127.0.0.1:3100 |
| Tempo | http://127.0.0.1:3200 |
| Pyroscope | http://127.0.0.1:4040 |
| Alloy UI | http://127.0.0.1:12345 |
| Demo | http://127.0.0.1:8080 |
| Nginx（反代 demo，stub_status 在容器内） | http://127.0.0.1:8088 |
| Collector OTLP gRPC / HTTP | 127.0.0.1:4317 / 127.0.0.1:4318 |
| Collector 自身指标 | http://127.0.0.1:8888/metrics |
| Collector 健康检查 | http://127.0.0.1:13133 |
| Collector zpages | http://127.0.0.1:55679/debug/tracez |
| node_exporter | http://127.0.0.1:9100/metrics |
| redis_exporter | http://127.0.0.1:9121/metrics |
| postgres_exporter | http://127.0.0.1:9187/metrics |
| nginx_exporter | http://127.0.0.1:9113/metrics |
| kafka_exporter | http://127.0.0.1:9308/metrics |

Kubernetes 上同名 Service 在命名空间 `observability`：`kubectl -n observability port-forward svc/grafana 3000:3000`。Collector zpages 在 Service `otel-collector` 的 `55679`。

## 配置先过一遍

```bash
make config-check
```

脚本 `scripts/config-check.sh` 会核对 `deploy/images.env`、解析 YAML/JSON、用 `alloy` 检查 River、用 `otelcol-contrib validate --feature-gates service.profilesSupport` 检查 Collector、`promtool check rules` 和 `promtool test rules config/prometheus/tests/alerts_test.yml`、`amtool check-config`、`loki -verify-config`、`kustomize build --load-restrictor LoadRestrictionsNone`、Terraform 覆盖检查，并跑 demo 单测。`alloy`、`otelcol-contrib`、`loki` 缺失是失败，不是跳过。`docker compose config` 是单独的可选渲染：没有 Docker CLI 时会写明 Compose 文件没有被校验。

单独重跑规则测试：

```bash
promtool test rules config/prometheus/tests/alerts_test.yml
promtool check rules config/prometheus/rules/*.yml
```

`promtool check config` 会去读容器里的 `/etc/prometheus/rules`。在宿主机上用上面的 `check rules`，不要对仓库里的 `prometheus.yml` 直接 `check config`。

## Grafana 里没有点

1. 确认进程在跑：`make ps`。demo 的健康检查是 `http://127.0.0.1:8080/healthz`。
2. 打流量：`make load`，或者 `curl -sS http://127.0.0.1:8080/api/work`。业务点还要打 `/api/orders` 和 `/api/checkout`。`make load` 已经包含这两条。
3. 指标大约每 5 秒导出一次（`OTEL_METRIC_EXPORT_INTERVAL=5000`）。刚启动先等一个导出周期。
4. 在 Prometheus 执行 `count(http_server_request_duration_seconds_count)`。有序列就说明 remote write 成功，问题在 Grafana 时间范围或查询。没有序列就看 Collector。
5. Collector 日志：`docker compose -f deploy/docker-compose/docker-compose.yml logs otel-collector`。remote write 失败时会出现 `otelcol_exporter_send_failed_metric_points_total`。
6. Prometheus 必须带着 `--web.enable-remote-write-receiver`。这个参数在 Compose command 和 `deploy/kubernetes/base/prometheus.yaml` 里。
7. 数据源 UID 必须是 `prometheus`。改 `config/grafana/provisioning/datasources/datasources.yaml` 时，仪表盘 JSON 里的 `uid` 要一起改。

主机面板依赖 job `node`。如果只起了 Alloy、没起 node-exporter，`instance:node_cpu_utilization:ratio` 是空的。Alloy 那份副本的 job 是 `alloy-unix`，可以临时查询 `node_cpu_seconds_total{job="alloy-unix"}` 确认机器指标其实到了。

## 抓取目标 down

打开 http://127.0.0.1:9090/targets 。`up == 0` 持续 2 分钟会触发 `TargetDown`。

对照 `config/prometheus/prometheus.yml` 里的 DNS：

| job | 目标 |
| --- | --- |
| prometheus | prometheus:9090 |
| alertmanager | alertmanager:9093 |
| loki | loki:3100 |
| tempo | tempo:3200 |
| pyroscope | pyroscope:4040 |
| grafana | grafana:3000 |
| otel-collector | otel-collector:8888 |
| alloy | alloy:12345 |
| node | node-exporter:9100 |
| redis | redis-exporter:9121 |
| postgres | postgres-exporter:9187 |
| nginx | nginx-exporter:9113 |
| kafka | kafka-exporter:9308 |

`kube-state-metrics` 不在这份静态配置里。Kubernetes 上由 Alloy 抓 `kube-state-metrics:8080` 再远程写入，job 名 `kube-state-metrics`。Compose 里没有这个目标，所以不会误报 `TargetDown`。

exporter 自身 up、后端 down 时，看的是组件指标而不是 `up`：`redis_up == 0`、`pg_up == 0`、`nginx_up == 0`、`kafka_brokers < 1`。nginx exporter 连的是 `http://nginx:8080/stub_status`，这个 location 只允许容器网段和 `127.0.0.1`。从宿主机 `curl http://127.0.0.1:8088/stub_status` 会被拒绝，这是预期的。

## 没有日志

1. ToC api 同时写 stdout JSON 和 OTLP log。Grafana 的 Logs 数据源 uid `loki` 只查 org `toc`：`{service_name="toc-api", tenant="consumer"}`。ToB 要换 `loki-tob-acme` 或 `loki-tob-northwind`。某个租户完全没有数时的顺序见 [tenancy.md](tenancy.md)。
2. Loki 把 OTLP 资源属性里的点换成下划线，所以是 `service_name`，不是 `service.name`。索引标签在 `config/loki/loki.yaml` 的 `otlp_config.resource_attributes`。
3. Collector 日志管道的 exporter 是 `otlphttp/loki`，地址 `http://loki:3100/otlp`，Collector 会再拼 `/v1/logs`。
4. 在 Prometheus 看 `sum(rate(loki_distributor_lines_received_total[5m]))`。是 0 说明 Loki 没收到。再看 `sum(rate(otelcol_exporter_send_failed_log_records_total[5m]))`。
5. 被限流时 `loki_discarded_samples_total` 的 `reason` 会是 `rate_limited`、`per_stream_rate_limit` 或 `stream_limit`。对应配置是 `limits_config` 里的 `ingestion_rate_mb`、`per_stream_rate_limit`、`max_global_streams_per_user`。
6. Kubernetes 上 Pod stdout 走 Alloy `loki.source.kubernetes`，推到 `http://loki:3100/loki/api/v1/push`，标签是 `namespace`、`pod`、`container`。这和 demo 的 OTLP 日志是两条路。

有 Loki 的 `logcli` 时：

```bash
logcli --addr=http://127.0.0.1:3100 query '{service_name="demo-app"}' --limit=5
```

没有 logcli 就用 HTTP：

```bash
curl -sG 'http://127.0.0.1:3100/loki/api/v1/query' \
  --data-urlencode 'query={service_name="demo-app"}' | head
```

## 没有链路

1. TraceQL：`{ resource.service.name = "demo-app" }`。Tempo 查询端口是 `3200`。
2. 应用 OTLP 指向 `otel-collector:4317`。Tempo 自己的 OTLP `4317/4318` 没有映射到宿主机，避免和 Collector 抢端口。
3. 尾部采样在 Collector 的 traces 管道里，`decision_wait: 5s`。成功的 trace 也会晚大约 5 秒才出现。错误 span（`/api/error`）和慢于 500ms 的 span 由单独的策略保留。
4. 现在 `sampling_percentage: 100`，所以不是采样把 trace 丢掉。如果有人把它改成 10，成功请求会缺，错误请求还在。这是采样偏差，不是导出失败。
5. Collector 到 Tempo 的 exporter 是 `otlp/tempo_*`，默认端点 `tempo:4317`。本地 Compose 把 `OTEL_EXPORTER_TLS_INSECURE` 设为 `true`（明文）。配置文件里的默认是 `false`，`stacks/attach-existing` 也默认 `false`，这样现有 HTTPS 端点走 TLS。不要把 CA 证书提交进 git。
6. Tempo 的 span metrics 远程写回 Prometheus，名字是 `traces_spanmetrics_*` 和 `traces_service_graph_request_total`。Traces 仪表盘读的是这些，不是应用直方图。

在 Prometheus 看 Tempo 是否在收：

```promql
sum(rate(tempo_distributor_spans_received_total[5m]))
sum by (reason) (rate(tempo_discarded_spans_total[5m]))
```

## 没有 Profile

1. 按租户看火焰图走 Pyroscope SDK：`PYROSCOPE_HTTP_URL=http://pyroscope:4040`，`tenant_id` 是 org id。ToC api 的选择器是 `{service_name="toc-api", tenant="consumer", cluster="local"}`，数据源 org 是 `toc`。不要在 org `rejected` 里找它。
2. `/api/work?burn_ms=40` 会进 `burn_cpu`。火焰图为空时先确认 `PYROSCOPE_HTTP_URL`，再确认 Pyroscope 进程在听 `4040`。
3. OTLP profiles 走 Collector 的 profiles 管道，只经过 `memory_limiter`，exporter 是 `otlp/pyroscope`，头固定 `X-Scope-OrgID: rejected`。Collector `0.161.0` 的 routing connector 不能按租户拆 profiles。这条管道需要 `--feature-gates=service.profilesSupport`。空的业务火焰图如果只查了 `rejected` 以外的 org，先改查 SDK 那条路径。
4. 丢弃看 `pyroscope_discarded_samples_total` 的 `reason`（例如 `rate_limited`、`label_name_too_long`）。

## 告警不触发

1. 规则文件在 `config/prometheus/rules/`。Prometheus 加载 `/etc/prometheus/rules/*.yml`。Kubernetes 用 ConfigMap `prometheus-rules`，`subPath` 挂整个目录时改完要重启 Pod。
2. 打开 http://127.0.0.1:9090/rules 看分组是否健康。失败计数是 `prometheus_rule_evaluation_failures_total`。
3. 告警有 `for`。`NodeDown` 是 2 分钟，`HighErrorRate` 是 5 分钟，`NodeDiskWillFill` 是 30 分钟且 `predict_linear` 需要约 6 小时样本。刚启动看不到是时间不够，不是规则没装。
4. `HighErrorRate` 还要求非 `/healthz` 的 QPS > 0.1。只打一两下 `/api/error` 不会响。
5. `BusinessPaymentFailureRatio` 要求失败占比 > 10% 且支付速率 > 0.05/s。`make load` 里失败结账大约是一半，速率要够。
6. Alertmanager http://127.0.0.1:9093 能看到告警。没设置 `ALERT_WEBHOOK_URL`（Terraform 是 `TF_VAR_alert_webhook_url`）时，`critical` 和 `warning` 接收器是故意留空的，告警留在界面里，不会外发。设置之后，这两个严重级别发到该 webhook，分组键是 `cluster`、`business_line`、`tenant`、`alertname`。没收到消息不代表没触发。每条告警的 `runbook_url` 指向本文「告警手册」里的锚点。
7. 用 promtool 对一条规则做单元测试，输入序列写在 `config/prometheus/tests/alerts_test.yml`。每层至少有一条：`NodeDown`、`RedisDown`、`HighErrorRate`、`BusinessPaymentFailureRatio`、`LokiSamplesDiscarded`。

## Collector 导出失败

1. `curl -sS http://127.0.0.1:8888/metrics | grep otelcol_exporter_send_failed`。
2. 同时看拒绝和丢弃：`otelcol_receiver_refused_`、`otelcol_processor_dropped_`。内存限制是 `memory_limiter` 的 75%。Compose 把 Collector 限制在 512m。
3. 队列：`otelcol_exporter_queue_size / otelcol_exporter_queue_capacity`。超过 0.8 持续 10 分钟是 `CollectorExporterQueueNearFull`。
4. zpages：http://127.0.0.1:55679/debug/tracez 看 Collector 内部 span。http://127.0.0.1:55679/debug/servicez 看扩展和管道。这是 Collector 的 zpages 扩展，端点写在 `config/otel-collector/config.yaml` 的 `extensions.zpages`，`0.0.0.0:55679`。
5. 健康检查：`curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:13133`，期望 200。
6. 校验配置：`otelcol-contrib validate --config config/otel-collector/config.yaml --feature-gates service.profilesSupport`。

Alloy 远程写失败看它自己的指标，不是 Collector 的：

```bash
curl -sS http://127.0.0.1:12345/metrics | grep prometheus_remote_storage_samples_failed_total
```

告警 `AlloyRemoteWriteFailures` 要求 `job="alloy"`，避免和别的进程的同名指标混在一起。

## 告警手册

每条 Prometheus 告警的 `runbook_url` 是 `docs/debugging.md#alert-<AlertName>`。下面的锚点都在这个文件里。告警留在 Alertmanager 和 Grafana 的界面里。只有设置了 `ALERT_WEBHOOK_URL`（Terraform 里是 `TF_VAR_alert_webhook_url`）时，`critical` 和 `warning` 才会发到那个 webhook。

<a id="alert-TargetDown"></a>
**TargetDown.** Scrape target is down

<a id="alert-CollectorExportFailures"></a>
**CollectorExportFailures.** OpenTelemetry Collector is failing to export telemetry

<a id="alert-CollectorRefusedData"></a>
**CollectorRefusedData.** OpenTelemetry Collector is refusing or dropping data

<a id="alert-CollectorExporterQueueNearFull"></a>
**CollectorExporterQueueNearFull.** Collector exporter queue is over 80% full

<a id="alert-DiskSpaceLow"></a>
**DiskSpaceLow.** Filesystem free space is below 15%

<a id="alert-NodeDown"></a>
**NodeDown.** Node exporter target is down

<a id="alert-NodeCPUSaturation"></a>
**NodeCPUSaturation.** Node CPU utilization is above 85%

<a id="alert-NodeMemorySaturation"></a>
**NodeMemorySaturation.** Node memory utilization is above 90%

<a id="alert-NodeLoadHigh"></a>
**NodeLoadHigh.** Node load average is above 2 per CPU

<a id="alert-NodeDiskWillFill"></a>
**NodeDiskWillFill.** Filesystem is predicted to fill within 4 hours

<a id="alert-KubePodNotReady"></a>
**KubePodNotReady.** Kubernetes pod is not ready

<a id="alert-KubeDeploymentUnavailable"></a>
**KubeDeploymentUnavailable.** Kubernetes deployment has unavailable replicas

<a id="alert-RedisDown"></a>
**RedisDown.** Redis exporter cannot reach Redis

<a id="alert-RedisMemorySaturation"></a>
**RedisMemorySaturation.** Redis memory is above 90% of maxmemory

<a id="alert-RedisRejectedConnections"></a>
**RedisRejectedConnections.** Redis is rejecting connections

<a id="alert-PostgresDown"></a>
**PostgresDown.** Postgres exporter cannot reach PostgreSQL

<a id="alert-PostgresConnectionSaturation"></a>
**PostgresConnectionSaturation.** PostgreSQL connections are above 80% of max_connections

<a id="alert-PostgresRollbackRatio"></a>
**PostgresRollbackRatio.** PostgreSQL rollback ratio is above 10%

<a id="alert-NginxDown"></a>
**NginxDown.** Nginx exporter cannot read stub_status

<a id="alert-NginxDroppedConnections"></a>
**NginxDroppedConnections.** Nginx is accepting connections it does not handle

<a id="alert-KafkaNoBrokers"></a>
**KafkaNoBrokers.** Kafka exporter sees no brokers

<a id="alert-KafkaConsumerLagHigh"></a>
**KafkaConsumerLagHigh.** Kafka consumer group lag is above 10000

<a id="alert-HighErrorRate"></a>
**HighErrorRate.** HTTP 5xx error ratio is above 5%

<a id="alert-HighLatency"></a>
**HighLatency.** HTTP p95 latency is above 500ms

<a id="alert-AppInFlightSaturation"></a>
**AppInFlightSaturation.** HTTP in-flight requests are above 100

<a id="alert-AppProcessCPUSaturation"></a>
**AppProcessCPUSaturation.** Process CPU utilization is above 90%

<a id="alert-BusinessPaymentFailureRatio"></a>
**BusinessPaymentFailureRatio.** Payment failure ratio is above 10%

<a id="alert-BusinessPaymentFailureBurn"></a>
**BusinessPaymentFailureBurn.** Payment failure ratio is burning on two windows

<a id="alert-PrometheusRuleEvalFailures"></a>
**PrometheusRuleEvalFailures.** Prometheus rule evaluation is failing

<a id="alert-PrometheusHighSeries"></a>
**PrometheusHighSeries.** Prometheus head series is above 200000

<a id="alert-PrometheusSeriesChurn"></a>
**PrometheusSeriesChurn.** Prometheus series churn is above 50 per second

<a id="alert-LokiSamplesDiscarded"></a>
**LokiSamplesDiscarded.** Loki is discarding log samples

<a id="alert-LokiStreamChurn"></a>
**LokiStreamChurn.** Loki is creating streams faster than 50 per second

<a id="alert-TempoSpansDiscarded"></a>
**TempoSpansDiscarded.** Tempo is discarding spans

<a id="alert-PyroscopeSamplesDiscarded"></a>
**PyroscopeSamplesDiscarded.** Pyroscope is discarding profiles

<a id="alert-AlloyRemoteWriteFailures"></a>
**AlloyRemoteWriteFailures.** Alloy remote write is failing

<a id="alert-GrafanaDown"></a>
**GrafanaDown.** Grafana scrape target is down

<a id="alert-AlertmanagerDown"></a>
**AlertmanagerDown.** Alertmanager scrape target is down

<a id="alert-SLOAvailabilityFastBurn"></a>
**SLOAvailabilityFastBurn.** Availability SLO fast burn

<a id="alert-SLOAvailabilitySlowBurn"></a>
**SLOAvailabilitySlowBurn.** Availability SLO slow burn

<a id="alert-SLOLatencyFastBurn"></a>
**SLOLatencyFastBurn.** Latency SLO fast burn

<a id="alert-TocPaymentFailureRatio"></a>
**TocPaymentFailureRatio.** ToC payment failure ratio is above 10%

<a id="alert-TobInvoiceFailureRatio"></a>
**TobInvoiceFailureRatio.** ToB invoice failure ratio is above 10%

<a id="alert-TobSeatSaturation"></a>
**TobSeatSaturation.** ToB seat utilization is above 90%

<a id="alert-TobApiQuotaHigh"></a>
**TobApiQuotaHigh.** ToB API quota utilization is above 90%

