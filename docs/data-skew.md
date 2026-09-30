# 数据倾斜和管道失败

这里的「倾斜」是指少数标签、少数流、少数服务把存储或管道撑满，其余目标看起来还正常。检测信号都在 meta 仪表盘（UID `meta`）和 `config/prometheus/rules/alerts.yml` 的 `meta-pipeline` 组里。

## 高基数标签

表现：`prometheus_tsdb_head_series` 涨得比流量快，`PrometheusHighSeries` 在 200000 以上响，`PrometheusSeriesChurn` 在 `rate(prometheus_tsdb_head_series_created_total[10m]) > 50` 时响。Loki 侧是 `loki_ingester_streams_created_total` 和 `LokiStreamChurn`。Pyroscope 会因标签名或值过长丢弃，`pyroscope_discarded_samples_total` 的 `reason` 是 `label_name_too_long`、`label_value_too_long` 或 `max_label_names_per_series`。

业务指标的允许表只有 `channel`、`method`、`result`、`segment`，每个只有两三个值。订单号、用户号不能当标签。

应用侧先收口。`examples/demo-app/src/demo_app/server.py` 的 `route_label` 把不认识的路径收成 `other`，避免一次路径扫描变成一条 `http_route` 序列。`business.py` 把未知 channel 收成 `other`。

Collector 再收一次。这是仓库里的「之后」配置（`config/otel-collector/config.yaml`）：

```yaml
processors:
  attributes/sanitize:
    actions:
      - key: user.id
        action: delete
      - key: order.id
        action: delete
      - key: url.full
        action: delete
  transform/business_labels:
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["channel"], "other") where metric.name == "business.orders.created" and attributes["channel"] != nil and attributes["channel"] != "web" and attributes["channel"] != "api" and attributes["channel"] != "other"
```

「之前」是没有这些 action、SDK 直接把 `user.id` 和原始 `channel` 送进 remote write。那样 `business_orders_created_total` 的序列数等于用户数。加上面的处理器之后，用户 id 不会变成标签，channel 只有三个值。

Prometheus 抓取侧的例子在 `config/prometheus/prometheus.yml` 的 redis job。之前：`redis_key_size{key="session:user:123"}` 一类序列会按 key 爆炸。之后：

```yaml
metric_relabel_configs:
  - source_labels: [__name__]
    regex: redis_key_.*
    action: drop
```

cAdvisor 的例子在 `config/alloy/config.k8s.alloy`。之前 scrape 直接 `forward_to` remote write，`id`、`container_id`、`image_id` 每个容器一份。之后先过 `prometheus.relabel "cadvisor_labels"`，`labeldrop` 这三个名字。容器 CPU 仍然按 `namespace`、`pod`、`container` 聚合。

## 热点指标名

表现：单个 `__name__` 的序列数远高于其他名字，`count by (__name__) ({__name__=~".+"})` 在 Prometheus 里能看出来（这个查询很贵，时间范围放短）。Collector 侧如果某个 exporter 队列先满，`platform:collector_queue_utilization:ratio` 会按 `exporter` 分开，热点往往是 metrics 管道而不是 traces。

缓解：

- 不要为调试临时加一个带用户 id 的 counter。加了就要在 `attributes/sanitize` 里删键。
- 直方图桶已经写死。HTTP 是 `HTTP_DURATION_BUCKETS`，结账是 `CHECKOUT_DURATION_BUCKETS`。不要在运行时按路由动态改桶。
- Redis 的 key 级指标保持关闭，并用上面的 relabel 兜底。

## 日志流不均

表现：`sum by (tenant) (loki_ingester_memory_streams)` 里某一个 org 特别高。Loki 已打开 `auth_enabled: true`，这里的 `tenant` 是 `X-Scope-OrgID`（`toc`、`tob-acme`、`tob-northwind`、`platform`、`rejected`），不是终端用户。org 内部的倾斜仍在标签组合上：某个 `service_name` 配上了高基数标签。`loki_discarded_samples_total` 的 `reason="stream_limit"` 对应 `max_global_streams_per_user: 10000`。`per_stream_rate_limit` 对应单流过快。告警按 org 拆开，不会把两个 ToB 租户的丢弃加在一起。

检测：

```promql
sum(loki_ingester_memory_streams)
sum by (reason) (rate(loki_discarded_samples_total[5m]))
sum(rate(loki_ingester_streams_created_total[10m]))
```

缓解：索引标签只保留 `config/loki/loki.yaml` 里已经列出的资源属性。不要把 `service.instance.id` 从索引里拿掉之前先确认仪表盘没有按实例查；它已经在索引列表里，实例数应等于副本数，而不是请求数。新的标签先当结构化元数据，不要 `action: index_label`。

单流过大时，在应用里按一个低基数键拆日志流（例如已经有的 `service_name`），而不是按用户拆。Alloy 的 Pod 日志已经按节点切开，DaemonSet 不会重复采别的节点。

## 链路采样偏差

表现：Tempo 里错误 trace 很多、成功 trace 很少，但 `http_server_request_duration_seconds_count` 的 5xx 占比并不高。那是尾部采样把错误和慢请求留全、把成功请求按比例丢掉。`tempo_distributor_spans_received_total` 仍在涨，说明不是接收挂了。

当前配置是偏差最小的一档：`sampling_percentage: 100`，外加错误和慢请求策略。trace 仍会晚 `decision_wait`（5 秒）。

减量时的改法就在同一段配置里。之前：

```yaml
      - name: baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 100
```

之后（需要省磁盘时再改，改完错误和超过 500ms 的 trace 还在）：

```yaml
      - name: baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

不要只留 probabilistic、删掉 `errors` 策略，否则失败请求和成功请求一起被丢掉，排障时会低估故障。

`tempo_discarded_spans_total` 的 reason `rate_limited`、`trace_too_large`、`live_traces_exceeded` 是 Tempo 自己拒收，不是采样策略。告警是 `TempoSpansDiscarded`。

## 租户或服务不均

`cluster` 和 `tenant` 都是低基数身份标签。中心栈和 Compose 的 `cluster` 是 `local`。ToC 的 `tenant` 固定 `consumer`，ToB 只有允许表里的 id。跨集群、跨租户的倾斜是某一个格子的序列或日志流把中心存储撑满，其它格子的查询还在。看下面的查询之前先缩短时间范围。不要把 pod uid 或用户 id 加进这两个标签旁边。服务不均看：

```promql
topk(5, sum by (business_line, tenant, cluster, service_name) (rate(http_server_request_duration_seconds_count[5m])))
topk(5, sum by (business_line, tenant, cluster, service_name) (rate(business_payments_total{business_line="toc"}[5m])))
topk(5, sum by (tenant, cluster, service_name) (rate(business_invoices_total{business_line="tob"}[5m])))
```

一个 `service_name` 占满 remote write 队列时，`CollectorExporterQueueNearFull` 先响，其他服务的点会跟着延迟。缓解是把那个服务的无用标签删掉（通常就能降一个数量级）。工作负载 Collector 已经是两个无状态副本，但它们各自做 tail sampling，也写同一套中心单进程存储。加存储副本不在这份本地盘配置的范围内。

同一个 Loki org 里，`{service_name="某个吵的服务"}` 的行数可以用对应的 Grafana 数据源，或：

```bash
curl -sG \
  -H 'X-Scope-OrgID: toc' \
  -H 'Authorization: Bearer dev-ingest-token' \
  'http://127.0.0.1:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (service_name, cluster) (count_over_time({business_line="toc"}[5m]))'
```

`dev-ingest-token` 只用于本地。生产换成 Secret 里的口令。

换 org 时改头，不要改成一个用户 id。细节在 [tenancy.md](tenancy.md)。

## Prometheus 序列抖动

`platform:prometheus_series_created:rate10m` 持续高于 50，同时 `up` 都是 1，说明不是目标在重启，而是标签在变。常见来源：

- `http_route` 用了原始 URL。应用侧已收成 `KNOWN_ROUTES`，Collector 还会丢带 `?` 的点。
- cAdvisor 的容器 id。Kubernetes 配置已经 `labeldrop`。
- 业务 `channel` 用了活动名。允许表里没有活动名，会变成 `other`。

查完新序列后，在产生它的那一层删标签，不要只把 `PrometheusHighSeries` 的阈值调高。阈值 200000 是给这套单机加 demo 和四个中间件用的，不是生产集群的容量规划。

## Loki 流上限

`max_global_streams_per_user: 10000` 是硬限制。触顶后新流被丢，`LokiSamplesDiscarded` 的 reason 是流限制一类。已经存在的流还在。

缓解顺序：

1. 去掉刚加的索引标签。
2. 确认没有把 trace id 或用户 id 放进日志的 stream label。trace id 只留在 JSON 正文里，给派生字段跳转用。
3. 仍然不够再改 `max_global_streams_per_user`。改大之前先看 `loki_ingester_memory_streams`，内存会跟着涨。

## Collector 拒绝和丢弃

| 现象 | 指标 | 告警 | 怎么办 |
| --- | --- | --- | --- |
| 内存限制，数据进不来 | `otelcol_receiver_refused_spans_total` 等 | CollectorRefusedData | 加大 Compose `mem_limit` 或 Kubernetes memory limit，同时看是不是高基数把内存吃掉 |
| 处理器丢掉 | `otelcol_processor_dropped_*` | CollectorRefusedData | 同上。filter 主动丢带 `?` 的 route 也会计在 dropped 上，先看是不是误伤 |
| 发出去失败 | `otelcol_exporter_send_failed_*` | CollectorExportFailures | 看下游：Prometheus 9090、Loki 3100、Tempo 4317、Pyroscope 4040 |
| 队列堆积 | `otelcol_exporter_queue_size` / `otelcol_exporter_queue_capacity` | CollectorExporterQueueNearFull | 下游慢。队列长度在配置里是 `queue_size: 2000`，加长队列只是推迟失败 |

zpages http://127.0.0.1:55679/debug/tracez 能看到导出 span 的错误。自身指标端口是 http://127.0.0.1:8888/metrics 。

Alloy 写 Prometheus 失败是另一条管道：`prometheus_remote_storage_samples_failed_total{job="alloy"}`，告警 `AlloyRemoteWriteFailures`。主机指标和 cAdvisor 走这里，应用 RED 不走这里。
