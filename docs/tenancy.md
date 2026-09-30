# 多业务线与租户

这套平台同时观察多条业务线，而不是只挂一个 demo。目录在 `config/tenancy.yaml`。Compose、Collector、Grafana 数据源、Prometheus 规则、Kubernetes 工作负载都从这份地图生成。改业务或租户先改地图，再 `make render-tenancy`，最后由 Terraform 把生成结果应用到集群。不要按租户复制一份 YAML。

## 平台给谁用

| 业务线 | 形态 | 例子 | 隔离方式 |
| --- | --- | --- | --- |
| ToC | 面向个人用户的产品线 | `toc-api`、`toc-checkout` | 整条线一个合成租户 `consumer`。终端用户 id 不是租户 |
| ToB | 面向企业客户的产品线 | `tob-admin`、`tob-billing` | 每个企业客户一个租户，允许表目前是 `acme`、`northwind` |

两条线可以跑在同一个集群上，也可以各自跑在多个集群上。示例里 ToC 和 ToB 都声明了 `local`、`prod-a`、`prod-b`。`local` 是 Compose 和中心栈的集群名。

共享的基础设施（节点、Redis、PostgreSQL、Nginx、Kafka、Collector 自身）没有业务租户。它们只有 `cluster`。不要为了“五层都有 tenant”把节点指标打上租户。

## 租户模型

两套标识，不要混用：

| 名字 | 出现在哪 | 取值 | 作用 |
| --- | --- | --- | --- |
| `business_line` | 指标、日志、链路、Profile 标签 | `toc`、`tob` | 业务线。规则和仪表盘用它把两条线切开 |
| `tenant` | 同上 | `consumer`、`acme`、`northwind` | 业务租户。ToB 聚合必须带着它 |
| `org_id` / `X-Scope-OrgID` | Loki、Tempo 的请求头 | `toc`、`tob-acme`、`tob-northwind`、`platform`、`rejected` | 日志和链路的后端隔离。Grafana 每个 org 一个数据源 |

Prometheus 仍然是一套 TSDB，靠标签隔离。没有在这个钉死的单二进制上再挂一套 Mimir。Mimir 如果要加，必须是 `config-check` 能校验的真实配置，而不是一段打算。

Pyroscope 2.3.1 配合 `pyroscope-io` 1.2.4 的 HTTP 推送没有租户头。Profile 用标签 `cluster`、`tenant`、`business_line` 分开。不要把它说成已经按 org 隔离。

禁止进入指标标签的东西：

- 终端用户 id、订单 id、`user.id`、`order.id`、`customer.id`、`enduser.id`
- 查询串、原始 URL
- 不在允许表里的租户字符串

应用侧 `examples/demo-app/src/demo_app/identity.py` 会把不认识的 ToB 租户收成常量 `rejected`。Collector 的 `transform/tenancy` 再做一次，并且删掉资源上的用户 id。`rejected` 只有一个值，所以一次配错不会变成一万个序列，也不会在 Loki 里开出一个新 org。配错的日志和链路进 org `rejected`，用数据源 `loki-rejected` / `tempo-rejected` 看。

ToC 忽略调用方传来的任何租户。`BUSINESS_LINE=toc` 时标签永远是 `tenant=consumer`，即使有人传入 `acme` 或 `user-42`。

## 四条信号上的标签

| 信号 | 谁写上 `cluster` 和 `tenant` | 后端怎么隔开 |
| --- | --- | --- |
| 指标 | 应用资源属性，Collector `resource/cluster` 与 `transform/tenancy`，再经 remote write 变成标签 | Prometheus 标签。记录规则 `sum by (cluster, tenant, business_line, service_name)` |
| 应用日志 | 同上，然后 routing connector 按 `org_id` 选择 exporter | Loki `auth_enabled: true`，头 `X-Scope-OrgID` |
| 链路 | 同上 | Tempo `multitenancy_enabled: true`，同一个头。span metrics 维度含 `cluster`、`tenant`、`business_line` |
| Profile | Pyroscope SDK 的 tag，键就是这几个名字 | 标签。服务端仍是单租户进程 |
| 节点 / Pod 日志 | Alloy 只接受允许表里的 org。对不上的流进 `platform` | Loki org `platform`。Pod 标签 `observability.platform/org-id` 必须是 `toc`、`tob-acme`、`tob-northwind` 或 `platform` |

Alertmanager 按 `alertname`、`cluster`、`business_line`、`tenant`、`service_name` 分组。`acme` 的 critical 不会抑制 `northwind` 的 warning，ToC 也不会抑制 ToB。

## 本地 Compose 上有什么

`make up` 使用两份 Compose 文件：`deploy/docker-compose/docker-compose.yml` 和生成的 `deploy/docker-compose/businesses.yml`。集群标签都是 `local`。

| Compose 服务 | 业务 | 租户 | 角色 | 宿主机端口 | `service.name` |
| --- | --- | --- | --- | --- | --- |
| `demo-app` | ToC | `consumer` | api | 8080 | `toc-api` |
| `toc-checkout` | ToC | `consumer` | checkout | 8081 | `toc-checkout` |
| `tob-admin-acme` | ToB | `acme` | admin | 8082 | `tob-admin` |
| `tob-billing-acme` | ToB | `acme` | billing | 8083 | `tob-billing` |

`northwind` 在允许表、Collector 路由、Grafana 数据源和 Kubernetes 清单里，副本数是 0，Compose 不启动它。`:8080` 仍是原来的 demo 路由（`/api/work`、`/api/orders`、`/api/checkout`、`/api/error`），服务名改成了 `toc-api`。

ToB 路由：

| 路径 | 服务 | 指标 |
| --- | --- | --- |
| `GET /api/invoices?fail=0` | `tob-billing` | `business_invoices_total`，`result=success\|failure` |
| `GET /api/seats?plan=standard\|enterprise&count=1&limit=100` | `tob-admin` | `business_seats_active`、`business_seats_limit` |
| `GET /api/quota?class=standard\|enterprise&used=0&limit=1000` | `tob-admin` | `business_api_quota_used`、`business_api_quota_limit` |

`plan` 和 `class` 不在表里时收成 `other`。`count`、`used`、`limit` 是数值，不是标签。

## 接入一个 ToC 服务

1. 在 `config/tenancy.yaml` 的 `business_lines.toc.services` 加一项：`name`、`role`（`api` 或 `checkout`）、Compose 服务名和宿主机端口。
2. 进程设置：

```text
BUSINESS_LINE=toc
TENANT_ID=consumer
SERVICE_ROLE=api
OTEL_SERVICE_NAME=<服务名>
CLUSTER_NAME=<集群名>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
```

`TENANT_ID` 填别的值也会被收成 `consumer`。不要从请求里读用户 id 来填它。

3. `make render-tenancy`。它会重写 Collector 的允许表语句、规则和清单。ToC 只有一个 org `toc`，一般不用新增 Loki 数据源。
4. 仪表盘用 `business_line="toc"` 和 `tenant="consumer"`，并且带 `cluster`。不要 `sum without (tenant)`。
5. `make config-check`，再 `terraform apply`。

现成的对照是 `examples/demo-app`。`identity.py` 里的 `TOC_TENANT` 必须和 yaml 一致，`config-check` 会比对。

## 接入一个 ToB 租户

1. 在 `business_lines.tob.tenants` 增加一项。`id` 是 DNS 标签，`org_id` 必须是 `tob-<id>`。示例：

```yaml
- id: contoso
  org_id: tob-contoso
  compose: false
  replicas: 0
  host_ports:
    tob-admin: 8086
    tob-billing: 8087
```

`compose: true` 才会出现在本地 Compose。`replicas` 是中心集群里的副本数，0 表示清单在、Pod 不起。

2. 同时把 `examples/demo-app/src/demo_app/identity.py` 的 `TOB_TENANTS` 改成同一张表。两处不一致时 `make render-tenancy` 和 `config-check` 会失败。应用镜像不挂 yaml，所以进程内要有一份对照；Collector 仍是最后一道门。

3. `make render-tenancy`。生成物包括：

- Collector 里该 org 的 `X-Scope-OrgID` exporter 和 routing 表
- Grafana 数据源 `loki-tob-<id>`、`tempo-tob-<id>`
- `config/prometheus/rules/tenancy.yml` 里的 `tenant=~` 允许表
- Alloy 里的 org 正则（`config.k8s.alloy` 与 `config.workload.alloy`，检查脚本会比对）
- `deploy/kubernetes/base/business-workloads.yaml` 和 prod overlay 的环境补丁
- `deploy/docker-compose/businesses.yml`（仅 `compose: true`）
- 仪表盘 `tob-line.json` 上该 org 的日志面板

4. 业务进程：

```text
BUSINESS_LINE=tob
TENANT_ID=contoso
SERVICE_ROLE=admin
OTEL_SERVICE_NAME=tob-admin
CLUSTER_NAME=prod-a
```

Kubernetes 还要打 Pod 标签，Alloy 才不会把 stdout 推进错误的 org：

```yaml
observability.platform/org-id: tob-contoso
observability.platform/business-line: tob
observability.platform/tenant: contoso
```

标签值不在允许表里时，Alloy 不会用原始字符串当 org，流进 `platform`。

5. `make config-check`，然后在 `deploy/terraform/stacks/platform` 执行 `terraform apply`。Terraform 读同一份 yaml，校验 org id 形如 `tob-<id>`，并通过已经存在的 Kustomize 路径把生成的 ConfigMap 和 Deployment 交出去。

## 多个集群的流量怎么进同一个后端

工作负载集群不跑 Loki、Tempo、Prometheus、Pyroscope、Grafana。每个集群的 Alloy 和 Collector 把数据送到中心地址，并带上自己的 `cluster`。租户头在离开本集群之前就定了：Collector 按资源属性选择 org，不靠中心再猜。

```text
prod-a 的 tob-billing (TENANT_ID=acme)
  -> 本集群 Collector
  -> 资源属性 cluster=prod-a, business_line=tob, tenant=acme, org_id=tob-acme
  -> 指标 remote write 到中心 Prometheus（标签）
  -> 日志 OTLP 到中心 Loki，头 X-Scope-OrgID: tob-acme
  -> 链路 OTLP 到中心 Tempo，同一个头
```

同一租户跑在 `prod-a` 和 `prod-b` 时，后端 org 相同，`cluster` 标签不同。查询要同时写 org（选对数据源）和 `cluster`。把两个集群加在一起会掩盖只在一边出问题的发布。

中心 URL 仍由 Terraform 的 `workload_clusters` map 写入 ConfigMap `observability-endpoints`。租户 map 不替代集群 map。增加第三个集群仍然是：map 里加一项，并在 `providers.tf` 加一个 alias。`for_each` 不能把不同的 provider alias 传给不同实例，agent 清单继续走每个实例自己的 kubeconfig 调 `kubectl`。这件事没有因为租户而改变。

## 某个租户没有数据

按这个顺序，不要先改仪表盘阈值。

1. 确认 `config/tenancy.yaml` 里有这个 id，并且 `make render-tenancy` 之后 Collector 配置里有对应的 `X-Scope-OrgID`。没有这一段时，流量会进 `rejected`，不会进一个新 org。
2. 看进程环境变量 `BUSINESS_LINE` 和 `TENANT_ID`。ToB 拼错会在应用日志的资源属性里变成 `tenant=rejected`，原始字符串已经被丢掉。
3. 在 Prometheus 查：

```promql
count by (cluster, business_line, tenant, service_name) (
  http_server_request_duration_seconds_count
)
```

有 `rejected` 说明允许表没接住。完全没有这个 `service_name` 说明 OTLP 没到 Collector，或 `CLUSTER_NAME` 为空。

4. 日志要选对数据源。`loki` 这个 uid 固定查 org `toc`。`acme` 的日志在 `loki-tob-acme`。在 toc 数据源里查 `{tenant="acme"}` 会是空的，这不是采集故障。
5. 链路同样：`tempo` 是 org `toc`，`tempo-tob-acme` 才是 acme。Prometheus 指标上的 exemplar 默认跳到 uid `tempo`，所以 ToB 的 trace 跳转要在 ToB 仪表盘上用对应数据源，不能指望这一条默认链接。
6. Pod stdout 走 Alloy。看 Pod 标签 `observability.platform/org-id` 是否等于 `tob-acme` 这种 org id，而不是裸的 `acme`。对不上时日志在 org `platform`（数据源 `loki-platform`），指标仍可能在正确的租户里，因为指标不走 Alloy 的租户头。
7. Grafana 变量如果停在 `cluster=local`，`prod-a` 的线不会出现。ToB 仪表盘的 `tenant` 是单选，没有 All。选了 `northwind` 就看不到 `acme`。

## 基数和倾斜

租户和集群都是低基数：集群数乘以允许表的长度。倾斜的样子是某一个格子把中心存储撑满，其他格子不动。

指标，先按业务线和租户看序列数，时间范围放短：

```promql
topk(10, count by (business_line, tenant, cluster) ({__name__=~".+"}))
```

健康的形状是每个 `(business_line, tenant, cluster)` 一块稳定的序列，和该租户的服务数、节点数成比例。不健康的形状是某一个租户阶跃。常见原因是那个进程把用户 id、订单号或原始 URL 送了出来。`rejected` 突然变多，说明允许表外的值在被收口，去对 `TENANT_ID`，不要把阈值调高。

两个 ToB 租户不能加在一起看“业务线总量”来判断谁坏了。`tob:http_requests:rate5m` 和 `tob:invoices:failure_ratio5m` 的 `by` 里有 `tenant` 和 `cluster`。`toc:http_requests:rate5m` 只选择 `business_line="toc", tenant="consumer"`，ToB 的样本不会进这个数。`promtool test rules` 用一条很大的 ToB 序列断言了这一点。

日志的倾斜现在按 org 分开。`loki_discarded_samples_total` 和 `loki_ingester_memory_streams` 带 Loki 自己的 `tenant` 标签（这里是 org id，不是终端用户）。告警 `LokiSamplesDiscarded` 按 `cluster`、`tenant`、`reason` 聚合，不会把 `tob-acme` 和 `tob-northwind` 的丢弃加在一起。

在某个 org 内部再看流：

```bash
curl -sG -H 'X-Scope-OrgID: tob-acme' \
  'http://127.0.0.1:3100/loki/api/v1/query' \
  --data-urlencode 'query=sum by (service_name, cluster) (count_over_time({business_line="tob"}[5m]))'
```

某个 `cluster` 的流数远高于另一个，先看那个集群有没有把 trace id 或用户 id 放进索引标签。索引里允许 `cluster`、`tenant`、`business_line`，不允许 pod uid。

链路的尾部采样仍在每个集群自己的 Collector 上做。对比错误率时要带 `cluster` 和 `tenant`，否则会把采样更狠的集群和全量集群、把两个企业客户加在一起。

ToC 的热点指标是支付和结账（`business_payments_total`、`business_checkout_duration_seconds`）。ToB 的热点是发票、席位和配额（`business_invoices_total`、`business_seats_active`、`business_api_quota_used`）。不要用 ToC 的支付失败比去报警一个 ToB 租户。

## Terraform

```bash
# 改 config/tenancy.yaml 之后
make render-tenancy
make config-check

cd deploy/terraform/stacks/platform
terraform init
terraform plan
terraform apply
```

`terraform validate` 会 `yamldecode` 这份文件。`terraform plan` 时 `terraform_data.tenancy_catalog` 的 precondition 会拒绝不合格的 id：不是 DNS 标签，或 org id 不是 `tob-<id>`。输出 `tenancy_org_ids` 和 `tob_tenant_ids` 就是当前允许表。

Grafana 管理员密码仍然只来自环境变量 `TF_VAR_grafana_admin_password` 或集群里已有的 Secret。租户 id 写在数据源的 `secureJsonData` 里，是因为 Grafana 只能用这个字段发送 `X-Scope-OrgID`。它们是 `acme` 这种假 id，不是口令。不要往 tfvars 或这个文件里放密码。

kubeconfig、`terraform.tfvars`、state 都不入库。state 可能含有 Grafana 密码，远端 backend 要加密，见 `backend.tf.example`。

## 五层在每条业务线上落在哪

| 层 | ToC / ToB 上有什么 | 聚合 |
| --- | --- | --- |
| 基础设施 | 节点 CPU、磁盘。信号本身没有租户 | 只按 `cluster`。仪表盘 `toc-line` / `tob-line` 的第一块就是它 |
| 中间件 | 共享的 Redis 等 exporter，没有租户 | 只按 `cluster` |
| 应用 | RED。ToC 是 api 和 checkout，ToB 是 admin 和 billing | `cluster`、`tenant`、`business_line`、`service_name` |
| 业务 | ToC：订单、支付、结账延迟。ToB：发票失败比、席位占用、API 配额 | 同上。ToB 不按租户相加 |
| 平台自身 | Collector 队列、Loki 丢弃、Tempo 丢弃 | 管道按 `cluster`。Loki/Tempo 丢弃再按 org 的 `tenant` 标签 |

对应仪表盘 uid：`toc-line`、`tob-line`，以及原来的 `infrastructure`、`middleware`、`application`、`business`、`meta`。`application` 和 `business` 的变量 `business_line`、`tenant` 是单选，没有 All。
