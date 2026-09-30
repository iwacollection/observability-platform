# 接到已经存在的可观测系统

后端已经在跑的时候用这条路径。Prometheus（或 Mimir）的 remote write、Loki、Tempo、Pyroscope、Grafana 都不是这次安装出来的。Terraform 只做两件事：在工作负载集群上装采集端，以及把这个业务线的数据源、仪表盘和告警登记进现有 Grafana。

## 两条路径怎么选

| | `stacks/platform` | `stacks/attach-existing` |
| --- | --- | --- |
| 目录 | `deploy/terraform/stacks/platform` | `deploy/terraform/stacks/attach-existing` |
| 什么时候 | Prometheus、Loki、Tempo、Pyroscope、Grafana 由我们安装 | 这五样已经在别处 |
| apply 会创建 | 中心栈里的全部平台组件，外加每个工作负载集群的 agent | 只有工作负载集群的 agent。`manage_grafana = true` 时再登记数据源、一块已有仪表盘、一组 Grafana 告警 |
| apply 不会创建 | — | Prometheus、Loki、Tempo、Pyroscope、Grafana，以及 demo 工作负载 |
| kubeconfig | 中心集群，加上 `prod-a`、`prod-b` | 只有这一份工作负载集群的 `kubeconfig` |
| 口令 | `TF_VAR_ingest_token`，prod 中心必填。Grafana 管理员密码是 `TF_VAR_grafana_admin_password` | `TF_VAR_ingest_token` 必填。登记 Grafana 时还要 `TF_VAR_grafana_auth` |

笔记本上的 Docker Compose 仍然不走 Terraform。

`org_id` 是写给 Loki、Tempo、Pyroscope 和 Grafana 数据源的 `X-Scope-OrgID`。`tenant` 是指标和日志上的低基数标签。ToC 的 `tenant` 是 `consumer`，`org_id` 是 `toc`，两者不一样。

| 变量 | ToC | ToB acme | ToB northwind |
| --- | --- | --- | --- |
| `business_line` | `toc` | `tob` | `tob` |
| `tenant` | `consumer` | `acme` | `northwind` |
| `org_id` | `toc` | `tob-acme` | `tob-northwind` |

值必须和 `config/tenancy.yaml` 一致。`business_line = toc` 时只能是 `tenant = consumer`、`org_id = toc`。`business_line = tob` 时 `org_id` 必须是 `tob-` 加上 `tenant`。

## 这次 apply 装什么

工作负载集群上：

- 命名空间 `observability`
- Alloy（DaemonSet）、两个副本的 Collector、node-exporter、kube-state-metrics、NetworkPolicy
- ConfigMap `observability-endpoints`：`CLUSTER_NAME`、四条写入地址，以及 `TENANT`、`BUSINESS_LINE`、`ORG_ID`
- Secret `ingest-auth`，键 `token`，值来自 `TF_VAR_ingest_token`

Agent 把 `cluster`、`tenant`、`business_line` 送到你填的地址，并带 Bearer。URL 来自变量，不会落到 `prometheus.observability.svc`。

`manage_grafana = true` 时，在现有 Grafana 上：

- 数据源的 HTTP 头保留 `X-Scope-OrgID` 和 `Authorization`（`Bearer` 加上口令）
- 仪表盘是仓库里现成的 JSON：`business_line = toc` 用 `config/grafana/dashboards/toc-line.json`（uid `toc-line`），`tob` 用 `tob-line.json`（uid `tob-line`）
- 告警是该业务线在 `config/prometheus/rules/tenancy.yml` 里的规则，经 Grafana unified alerting 下发

ToC 的数据源 uid 是 `prometheus`、`loki`、`tempo`、`pyroscope`。ToB 仪表盘还要 `prometheus-tob-<id>` 和 `loki-tob-<id>`。`business_line = tob` 时，目录里每个 ToB 租户的 Prometheus、Loki、Tempo、Pyroscope 数据源都会登记，头里的 `X-Scope-OrgID` 是那个租户自己的 `tob-<id>`。这个集群实际写入的仍是变量 `tenant` 和 `org_id`。

## 假定已经存在

- 一个能收 remote write 的 Prometheus 或 Mimir
- 一个能收 push 和 OTLP 的 Loki
- 一个 Tempo OTLP gRPC，以及一个给 Grafana 查询的 HTTP 地址（通常 `:3200`）
- 一个 Pyroscope
- 一个打开了 HTTP API 的 Grafana
- 现有系统已经认的那串 Bearer 口令
- 工作负载集群上的应用会把 OTLP 打到本集群的 `otel-collector.observability.svc:4317`。这条路径不部署 `demo-app`

现有 Prometheus 在远端，不能把 `config/prometheus/rules/*.yml` 拷进去。所以告警不走 Prometheus 规则文件，走 Grafana。`tenancy.yml` 里的记录规则被展开进告警查询，远端不会出现 `toc:payments:failure_ratio5m` 这种记录规则。

Collector 里 Loki、Tempo、Pyroscope 的 OTLP exporter 仍是 `tls.insecure: true`，只适合明文。现有端点如果是 TLS，这条路径还接不上。Prometheus remote write 看 URL 的 scheme，`https://` 会走 TLS。

OTLP profiles 仍然进 Pyroscope 的 `rejected` org。Collector 0.161 不能按租户给 profiles 选择 `X-Scope-OrgID`。直接推 Pyroscope HTTP 的 SDK 使用 ConfigMap 里的 `PYROSCOPE_HTTP_URL`，org 由 SDK 自己的 `tenant_id` 决定。

## init、plan、apply

```bash
cd deploy/terraform/stacks/attach-existing
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`。样例主机是 `example.invalid`，换成现有系统的地址。不要提交 `terraform.tfvars`，也不要把 kubeconfig 放进仓库。

```bash
export TF_VAR_ingest_token='现有系统的写入口令'
export TF_VAR_grafana_auth='现有 Grafana 的 API token'
terraform init
terraform plan
terraform apply
```

`TF_VAR_ingest_token` 是原始口令。Agent 用它做 Bearer，Grafana 数据源的 `Authorization` 是 `Bearer <token>`。不要在 tfvars 里写 `ingest_token` 或 `grafana_auth`。

没有集群、也不想连 Grafana 时，在仓库根目录跑 `make config-check` 或 `make terraform-check`。它会 `terraform fmt`、覆盖检查、对 `stacks/platform` 和 `stacks/attach-existing` 做 `terraform init -backend=false` 和 `terraform validate`。`validate` 不读 kubeconfig，也不访问 Grafana。

`terraform plan` 和 `terraform apply` 会读 `kubeconfig`。`manage_grafana = true` 时还会调用现有 Grafana 的 API。不要对一个不存在的集群 apply。

状态里会有口令和 `Authorization` 头。`*.tfstate` 已被 gitignore。远端状态用 `backend.tf.example` 做样子，复制成 `backend.tf` 后自己填，并打开加密。不要提交带密钥的 backend。

### 变量

| 变量 | 必填 | 含义 |
| --- | --- | --- |
| `cluster_name` | 是 | 标签 `cluster`。DNS 标签 |
| `kubeconfig` | 是 | 只这一份工作负载集群 |
| `kube_context` | 否 | 空则用 kubeconfig 的当前 context |
| `business_line` | 是 | `toc` 或 `tob`。决定仪表盘文件 |
| `tenant` | 是 | 标签 `tenant` |
| `org_id` | 是 | `X-Scope-OrgID` |
| `prometheus_remote_write_url` | 是 | 现有 Prometheus / Mimir 的 remote write |
| `loki_push_url` | 是 | 现有 Loki 的 push，以 `/loki/api/v1/push` 结尾 |
| `tempo_otlp_endpoint` | 是 | 现有 Tempo 的 gRPC，`host:port`，不带 scheme |
| `tempo_query_url` | 是 | Grafana 查 Tempo 的 HTTP 地址 |
| `pyroscope_url` | 是 | 现有 Pyroscope 的 HTTP 基址，带端口 |
| `grafana_url` | 是 | 现有 Grafana |
| `ingest_token` | 是 | 只通过 `TF_VAR_ingest_token` 传入。sensitive |
| `grafana_auth` | 登记 Grafana 时必填 | 只通过 `TF_VAR_grafana_auth` 传入。sensitive |
| `manage_grafana` | 否 | 默认 `true`。第二个集群设 `false` |
| `collector_replicas` | 否 | 默认 `2`，范围 2 到 5 |
| `prometheus_query_url` | 否 | 查询地址和 remote write 不在同一主机时填写 |
| `loki_query_url` | 否 | push URL 不是标准后缀时填写 |
| `loki_otlp_endpoint` | 否 | 默认是 push URL 的源加上 `/otlp`。Collector 再拼 `/v1/logs` |

## 再加一个集群

一份状态对应一个 `cluster_name`。第一个集群 `manage_grafana = true`。

第二个集群：

1. 另开一份状态。可以是另一个目录里的同一套栈，也可以 `terraform workspace new prod-b`。
2. `cluster_name` 换成新名字，例如 `prod-b`。`kubeconfig` 指向那个集群。
3. `prometheus_remote_write_url`、`loki_push_url`、`tempo_otlp_endpoint`、`pyroscope_url`、`grafana_url`、`tempo_query_url`、`business_line`、`tenant`、`org_id` 与第一个集群相同。
4. `manage_grafana = false`。数据源、`toc-line` 或 `tob-line`、告警已经在第一份状态里。
5. 导出同一个 `TF_VAR_ingest_token`。`manage_grafana = false` 时可以不设 `TF_VAR_grafana_auth`。
6. `terraform init`，`terraform plan`，`terraform apply`。

不要让两份状态同时 `manage_grafana = true`，它们会抢同一个仪表盘 uid 和数据源 uid。

## 换成另一个 ToB 租户

保持 `business_line = "tob"`。只改标签和 org，再 apply：

```hcl
business_line = "tob"
tenant        = "northwind"
org_id        = "tob-northwind"
```

从 northwind 回到 acme 就是 `tenant = "acme"`、`org_id = "tob-acme"`。

Agent 会改写 `tenant`、`business_line` 和 `X-Scope-OrgID`。ToB 仪表盘 JSON 同时引用 acme 和 northwind 的数据源 uid，所以这次 apply 仍会保留两个租户的数据源，只是这个集群写出的序列换成新的 `tenant`。

目录里没有的租户不能写进这两个变量。先改 `config/tenancy.yaml`，`make render-tenancy`，`make config-check`，再改这里的 `tenant` 和 `org_id`。否则 Collector 会把标签收成 `rejected`，数据进隔离 org，仪表盘上像没有数。

ToC 和 ToB 不要在同一个 Grafana 上用两份 `manage_grafana = true` 的状态去创建 uid `prometheus`。那一个 uid 只能有一个所有者。

## 现有 Grafana 里没有数据

按这个顺序看。

1. `kubectl -n observability get pods`。`alloy` 和 `otel-collector` 要 Ready。Secret 没有建好时 Pod 会停在 `CreateContainerConfigError`，补上 `TF_VAR_ingest_token` 再 apply。
2. `kubectl -n observability get configmap observability-endpoints -o yaml`。
   - `CLUSTER_NAME` 等于 `cluster_name`
   - `TENANT`、`BUSINESS_LINE`、`ORG_ID` 等于 tfvars
   - `PROMETHEUS_REMOTE_WRITE_URL` 等于 `prometheus_remote_write_url`
   - `LOKI_PUSH_URL` 等于 `loki_push_url`
   - `TEMPO_OTLP_ENDPOINT` 等于 `tempo_otlp_endpoint`
   - `PYROSCOPE_OTLP_ENDPOINT` 是 `pyroscope_url` 去掉 `http://` 或 `https://`
   - 这些值里不能出现 `prometheus.observability.svc`
3. 从工作负载集群里对 `prometheus_remote_write_url` 做一次连通性检查。网络不通时 Collector 日志里是导出失败，Grafana 仍是空的。
4. 现有 Grafana 的数据源里，`X-Scope-OrgID` 必须等于该 uid 对应的 org，`Authorization` 必须是 `Bearer` 加上 `TF_VAR_ingest_token`。ToB 业务面板的数据源 uid 是 `prometheus-tob-<tenant>`、`loki-tob-<tenant>`，基础设施面板才是 uid `prometheus`。
5. 在现有 Prometheus 上查：

   ```promql
   http_server_request_duration_seconds_count{cluster="prod-a",business_line="toc",tenant="consumer"}
   ```

   把标签换成你的 `cluster_name`、`business_line`、`tenant`。有序列但 Grafana 没有，多半是数据源 URL 或请求头。把 remote write 地址（带 `/api/v1/write`）填进数据源会查不到，查询地址应是去掉这个后缀的 `prometheus_query_url`。
6. Loki 查询必须带同一个 `X-Scope-OrgID`。写进 `toc`、用 `tob-acme` 的数据源去看，结果是空的。
7. 序列的 `tenant` 或 `business_line` 是 `rejected`：应用送上来的值不在 `config/tenancy.yaml` 的允许表里。改目录并渲染，或把栈的 `tenant` 改成允许表里的 id。
8. 仪表盘 uid 是 `toc-line` 或 `tob-line`，在文件夹 `attach-toc` 或 `attach-tob`。右上角集群变量要选中 `cluster_name`。时间范围拉到有流量的那段。
9. `manage_grafana = false` 不会创建数据源。到 `manage_grafana = true` 的那份状态里看 Grafana 资源。
10. Collector 日志出现 TLS 错误：这条路径的 Loki / Tempo / Pyroscope OTLP 仍是明文（`tls.insecure: true`）。现有系统只收 HTTPS 时，还不能用这份 exporter 配置。
11. 应用如果把 OTLP 打到现有 Tempo，而不是本集群的 Collector，`cluster` 标签不会被 gateway 盖成 `cluster_name`。应打到 `otel-collector.observability.svc:4317`。

Profile 火焰图仍然可能空着：OTLP profiles 进的是 org `rejected`，不进 `org_id`。这是 Collector 版本的限制，不是数据源头漏了。
