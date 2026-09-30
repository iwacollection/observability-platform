# 接入数据

应用只认 Collector 的 OTLP。主机和中间件走 Prometheus 抓取。Kubernetes 节点日志走 Alloy。业务指标是应用里的自定义仪器，标签必须落在允许表里。

资源属性至少三个：

| 属性 | Prometheus / Loki 标签 | 本仓库的值 |
| --- | --- | --- |
| `service.name` | `service_name` | ToC api 是 `toc-api`，结账是 `toc-checkout`；ToB 是 `tob-admin`、`tob-billing` |
| `service.namespace` | `service_namespace` | 固定 `observability` |
| `deployment.environment` | `deployment_environment` | Compose `local`，Kustomize dev/prod 分别是 `dev` / `prod` |
| `cluster` | `cluster` | Compose 和中心栈是 `local`。工作负载集群是 Terraform map 的键，例如 `prod-a`。一个集群一个值 |
| `business_line` | `business_line` | `toc` 或 `tob` |
| `tenant` | `tenant` | ToC 固定 `consumer`。ToB 只允许 `config/tenancy.yaml` 里的 id，例如 `acme`、`northwind` |

不要把用户 id、订单 id、完整 URL、查询字符串放进资源属性或数据点属性。Collector 会删掉一批键，但删之前它们已经进过内存。

## 应用：OpenTelemetry SDK

Demo 的接线在 `examples/demo-app/src/demo_app/telemetry.py`。关掉导出（单测）用 `OTEL_ENABLED=false`。

Compose 环境变量（`deploy/docker-compose/docker-compose.yml` 的 `demo-app`）：

```yaml
environment:
  OTEL_SERVICE_NAME: toc-api
  BUSINESS_LINE: toc
  TENANT_ID: consumer
  SERVICE_ROLE: api
  CLUSTER_NAME: local
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317
  OTEL_METRIC_EXPORT_INTERVAL: "5000"
  OTEL_METRICS_EXEMPLAR_FILTER: trace_based
  PYROSCOPE_HTTP_URL: http://pyroscope:4040
  DEPLOYMENT_ENVIRONMENT: local
```

集群内 gRPC 是 `http://otel-collector:4317`。别的命名空间用 `http://otel-collector.observability.svc:4317`。跑在宿主机上的进程用 `http://127.0.0.1:4317`。

HTTP 直方图用语义约定名 `http.server.request.duration`，单位秒。属性只用 `http.route`、`http.request.method`、`http.response.status_code`。`http.route` 必须是路由模板，不能是带查询串的路径。Demo 把不在 `KNOWN_ROUTES` 里的路径收成 `other`。

运行时指标不要再采一遍主机。`PROCESS_METRIC_CONFIG` 只开了 `process.*`、`process.runtime.*` 和 `cpython.gc.collections`。主机 CPU 用 node_exporter。

Python 之外的语言同样把 OTLP exporter 指到上面的地址。Collector 不关心语言。

## OTLP HTTP 和 gRPC

Collector 接收端（`config/otel-collector/config.yaml`）：

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

gRPC 用 `4317`。OTLP/HTTP 用 `4318`，路径是 `/v1/traces`、`/v1/metrics`、`/v1/logs`。本机映射是 `127.0.0.1:4317` 和 `127.0.0.1:4318`。

一条 HTTP 冒烟（没有 protobuf 时只能说明端口开着；正式接入用 SDK）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4318/v1/traces
```

没有 body 时期望 400 一类的响应，而不是连接拒绝。

Alloy 也听 `4317/4318`，再转到 `otel-collector:4317`。Demo 默认不走 Alloy。已经把流量打到节点代理上的进程可以继续用 Alloy，网关仍然是 Collector。

工作负载集群的 `config/alloy/config.workload.alloy` 在接收 OTLP 之前要求 bearer。请求头是：

```text
Authorization: Bearer <INGEST_TOKEN>
```

`<INGEST_TOKEN>` 就是 Secret `ingest-auth` 里的 `token`，也是 Alloy 转发给 Collector 时带的同一串。没有这个头的客户端会被拒绝，不能借集群的写入口令把数据送出去。本地占位是 `dev-ingest-token`。生产口令只通过 `TF_VAR_ingest_token` 进入 Secret，不要写进 git。

别的命名空间要打到 Alloy 的 OTLP，Pod 和它所在的命名空间都要有标签 `observability.platform/otlp-client=true`。NetworkPolicy 只对这个来源放开 `4317` 和 `4318`。

## Prometheus 抓取

平台自身、node_exporter 和中间件 exporter 写在 `config/prometheus/prometheus.yml` 的 `scrape_configs`。抓取间隔 15 秒。不要把 demo 加进 scrape：它没有 `/metrics`，`up` 会一直是 0，`TargetDown` 会响。

新的中间件 exporter 要同时满足三件事，否则 Compose 和 Kubernetes 会分叉：

1. 进程和 Service 用同一个 DNS 名，例如 `redis-exporter`。
2. 在 `prometheus.yml` 增加一个 `job_name`，目标是 `redis-exporter:9121`。
3. Compose `ports` 绑 `127.0.0.1`，Kubernetes Service 端口与容器端口一致。镜像标签写进 `deploy/images.env`，并出现在 Compose 和 Kustomize 里。

Redis 抓取带了丢弃规则，防止以后打开按 key 统计：

```yaml
  - job_name: redis
    static_configs:
      - targets: ["redis-exporter:9121"]
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: redis_key_.*
        action: drop
```

## 远程写入

Prometheus 打开了 `--web.enable-remote-write-receiver`。写入 URL 是 `http://prometheus:9090/api/v1/write`。

三处在用它，改地址时一起改：

| 谁 | 文件 |
| --- | --- |
| Collector 指标 | `config/otel-collector/config.yaml` 的 `exporters.prometheusremotewrite` |
| Alloy 主机 / cAdvisor / kube-state | `config/alloy/config.alloy` 和 `config/alloy/config.k8s.alloy` |
| Tempo span metrics | `config/tempo/tempo.yaml` 的 metrics generator remote write |

没有鉴权。不要把 9090 暴露到公网。

工作负载集群不解析 `prometheus` 这个 Service 名。Alloy 的 `PROMETHEUS_REMOTE_WRITE_URL` 和 Collector 的 `PROMETHEUS_REMOTE_WRITE_URL` 指向中心集群上可达的地址，并在写出时带上 `cluster`。日志推送是 `LOKI_PUSH_URL`（Alloy）和 `LOKI_OTLP_ENDPOINT`（Collector）。链路是 `TEMPO_OTLP_ENDPOINT`，Profile 是 `PYROSCOPE_OTLP_ENDPOINT`（OTLP）和 `PYROSCOPE_HTTP_URL`（Pyroscope SDK）。Compose 把这些变量设成 Docker 网络里的服务名，管道相同。键的清单在 `deploy/kubernetes/base/endpoints.yaml`。

## Loki：OTLP 和 Alloy

应用日志走 Collector：

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
```

SDK 打 OTLP log，正文是一行 JSON，里面有 `trace_id`。Grafana Loki 数据源用正则 `"trace_id":"([0-9a-f]+)"` 跳到 Tempo。

Kubernetes Pod 日志不经过 Collector。Alloy 配置：

```alloy
loki.write "default" {
	endpoint {
		url = "http://loki:3100/loki/api/v1/push"
	}
}
```

发现规则只保留 `NODE_NAME` 上的 Pod，标签是 `namespace`、`pod`、`container`、`app`。不要把 `pod_uid` 或完整日志行推进标签。

Loki 已打开多租户。推一条测试日志时要带 org，ToC 用 `toc`，ToB 用 `tob-acme` 或 `tob-northwind`。不要用用户 id 当 org：

```bash
curl -sS -H 'Content-Type: application/json' \
  -H 'X-Scope-OrgID: toc' \
  -H 'Authorization: Bearer dev-ingest-token' \
  -d '{"streams":[{"stream":{"service_name":"toc-api","tenant":"consumer","business_line":"toc","cluster":"local"},"values":[["'$(date +%s%N)'","{\"msg\":\"hello\"}"]]}]}' \
  http://127.0.0.1:3100/loki/api/v1/push
```

`dev-ingest-token` 是本地占位。生产口令放在 `TF_VAR_ingest_token`，由 Terraform 写入 Secret `ingest-auth`。

应用日志平时不走这条 curl，而走 Collector。Collector 按 `config/tenancy.yaml` 的允许表选择 org。`service_name`、`tenant`、`business_line`、`cluster` 可以当标签。不要把用户 id 放进 `stream`。接入步骤在 [tenancy.md](tenancy.md)。

## 中间件 exporter

| 组件 | 进程 | exporter | 指标端口 | 配置 |
| --- | --- | --- | --- | --- |
| Redis 7.4.6 | `redis:6379` | redis_exporter v1.74.0 | 9121 | `REDIS_ADDR=redis://redis:6379`，`config/redis/redis.conf` |
| PostgreSQL 17.6 | `postgres:5432` | postgres_exporter v0.17.1 | 9187 | `DATA_SOURCE_NAME=postgresql://postgres@postgres:5432/postgres?sslmode=disable`。Compose 和 Kubernetes 都用 `trust`，没有密码进 git |
| Nginx 1.28.0 | `nginx:8080`，宿主机 `127.0.0.1:8088` | nginx-prometheus-exporter 1.4.2 | 9113 | `--nginx.scrape-uri=http://nginx:8080/stub_status` |
| Kafka 3.9.1 | `kafka:9092` | kafka_exporter v1.9.0 | 9308 | `--kafka.server=kafka:9092` |
| 主机 | node_exporter v1.9.1 | 自身 | 9100 | `/host/proc`、`/host/sys`、`/host/root` |

Postgres 连接串没有密码，因为 `POSTGRES_HOST_AUTH_METHOD=trust` 只在这套本地网络里使用。接到真实数据库时把口令放进 Kubernetes Secret 或 Compose secret 文件，用 `DATA_SOURCE_PASS_FILE`，不要写进 git。

## 业务自定义仪器

在进程里创建仪器，不要把订单号当标签。允许表：

```text
channel: web | api | other
method:  card | wallet | other
result:  success | failure
segment: anonymous | authenticated
```

Demo 的实现：

```python
meter.create_counter(name="business.orders.created", unit="{order}")
meter.create_counter(name="business.payments", unit="{payment}")
meter.create_histogram(name="business.checkout.duration", unit="s")
meter.create_gauge(name="business.users.active", unit="{user}")
```

单位用 `{order}` 这种花括号，Collector 不会再追加单位后缀，Prometheus 名是 `business_orders_created_total`。不要用单位 `1` 做计数 gauge，否则名字会被加上 `_ratio`。

未知取值在 `business.py` 里收成 `other` / `failure` / `anonymous`。Collector 再做一次同样的改写，见 `processors.transform/business_labels`。两处的字符串必须保持一致，`make config-check` 会核对 `web`、`api`、`card`、`wallet`、`anonymous`、`authenticated` 同时出现在 `business.py` 和 Collector 配置里。

打点：

```bash
curl -sS 'http://127.0.0.1:8080/api/orders?channel=web'
curl -sS 'http://127.0.0.1:8080/api/checkout?method=card&fail=1&segment=authenticated&delay_ms=0'
```

`channel=user-123` 会以 `channel="other"` 入库。响应 JSON 里的 `channel` 就是记进指标的那个值。
