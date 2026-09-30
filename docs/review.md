# 仓库检视

检视对象是改动前的这套 OpenTelemetry LGTM 仓库：Compose、Kustomize、`config/` 和 `docs/`。下面每一条都能在当时的文件里指出来，并且会挡住多集群或 Terraform 操作。后面的「这次改了什么」对应该条在当前树里的落点。

## 1. 单集群假设

`deploy/kubernetes/base/kustomization.yaml` 把 namespace 固定成 `observability`，并把 Prometheus、Loki、Tempo、Pyroscope、Grafana、Alertmanager、Collector、Alloy、demo 和中间件放进同一份 base。`overlays/dev` 和 `overlays/prod` 只改磁盘、资源和 `DEPLOYMENT_ENVIRONMENT`，两边都是完整中心栈的单副本。仓库里没有「只装 agent」的清单。

Alloy 和 Collector 使用集群内 DNS：`config/alloy/config.k8s.alloy` 写 `http://prometheus:9090/api/v1/write` 和 `http://loki:3100/loki/api/v1/push`，`config/otel-collector/config.yaml` 写 `prometheus:9090`、`loki:3100`、`tempo:4317`、`pyroscope:4040`。这些名字只在跑着中心栈的那个命名空间里能解析。第二个工作负载集群里没有这些 Service。

`deploy/kubernetes/base/node-exporter.yaml` 当时写明：一个 Service 挡在 DaemonSet 前面，只适合单节点；多节点要改服务发现。`config/prometheus/prometheus.yml` 的 job `node` 目标是 `node-exporter:9100`。中心 Prometheus 抓不到另一个集群的节点，也抓不到本集群里 Service 没选中的那些节点。

README「五层和后续演进」写的是「而不是在这个仓库里拆成多集群」。这和「要接入多个集群」直接冲突。

这次改了什么：

- 新增 `deploy/kubernetes/agent`，复用 base 里的 Alloy、Collector、node-exporter、kube-state-metrics、NetworkPolicy，不复制 Deployment，也不带中心存储。
- 新增 `config/alloy/config.workload.alloy`。它按节点抓取 node-exporter，job 仍是 `node`，`instance` 用节点名，避免 Pod IP 抖动。
- 中心栈的静态抓取保留给 Compose 和中心集群自己的 `node-exporter:9100`。工作负载集群不再依赖那条静态目标。

## 2. 没有可用的集群身份

`config/prometheus/prometheus.yml` 的 `external_labels.cluster` 当时是字符串 `observability`。Prometheus 的 external label 只在告警和外向 remote write 时附上，不会写进本地 TSDB。Grafana 查本机 Prometheus 看不到这个标签。

`config/tempo/tempo.yaml` 的 metrics generator 把 `cluster: observability` 写成常量。所有集群的 span metrics 都会被盖成同一个值，工作负载集群无法分开。

`config/alloy/config.alloy` 和 `config/alloy/config.k8s.alloy` 的 `prometheus.remote_write` 没有 `external_labels`。Collector 的 `prometheusremotewrite` 也没有。应用资源属性里没有 `cluster`（`examples/demo-app/src/demo_app/telemetry.py`）。Loki 的 OTLP 索引列表（`config/loki/loki.yaml`）没有 `cluster`。

`config/prometheus/rules/recording.yml` 使用 `sum by (service_name)`。一旦序列上有了 `cluster`，这种聚合会把两个集群加在一起。`config/alertmanager/alertmanager.yml` 的 `group_by` 和 inhibit `equal` 没有 `cluster`，同名告警会跨集群合并或互相抑制。

五层仪表盘（`infrastructure.json`、`middleware.json`、`application.json`、`business.json`、`meta.json`）的 `templating.list` 是空的，查询也不按集群过滤。

这次改了什么：

- 中心 Prometheus 用 `metric_relabel_configs` 把抓取到的序列写成 `cluster=local`，`external_labels.cluster` 也改成 `local`，和 Compose 默认一致。Remote write 进来的样本不经过这段 relabel，工作负载自己的 `cluster` 会原样留下。
- Alloy remote write 和 Loki push 增加 `external_labels.cluster = sys.env("CLUSTER_NAME")`。
- Collector 增加 `resource/cluster`，并用 exporter 的 `external_labels.cluster`。默认值是 `local`，环境变量可覆盖。
- Tempo 去掉常量 `cluster`，在 span metrics 和 service graph 上增加维度 `cluster`（来自 trace 的资源属性）。
- Loki OTLP 索引增加 `cluster`。
- 记录规则和按集群生效的告警把 `cluster` 留在 `by` 里。`promtool test rules` 增加了 prod-a / prod-b 不能并成一条 `slo:http_requests:rate5m` 的用例。
- Alertmanager 的分组和抑制加上 `cluster`。
- 五层仪表盘增加模板变量 `cluster`，默认 `local`，查询带 `cluster="$cluster"`。
- Demo 从 `CLUSTER_NAME` 读取资源属性和 Pyroscope tag，默认 `local`。

## 3. 只有 YAML，没有 Terraform

部署入口是 README 第 8 节的 `kustomize build | kubectl apply`。仓库里没有 `.tf` 文件，没有 provider，没有 remote state，也没有按 kubeconfig 区分集群的方法。再加一个集群就要换 kubeconfig 再执行一遍同一条命令，清单和变量混在一起，销毁其中一个集群没有状态可循。

这次改了什么：

- `deploy/terraform/modules/central` 对 `deploy/kubernetes/overlays/<dev|prod>` 做 kustomize build 再 `kubectl apply`。YAML 仍是清单来源。
- `deploy/terraform/modules/cluster_agent` 对 `deploy/kubernetes/agent` 做同样的事，并写入该集群的 `observability-endpoints` ConfigMap。
- `deploy/terraform/stacks/platform` 用 `module "workload" { for_each = ... }` 实例化 agent。示例 map 里有 `prod-a` 和 `prod-b`。
- Provider 钉在 `hashicorp/kubernetes` `2.38.0`。alias `central`、`prod_a`、`prod_b` 各自绑定 kubeconfig。`modules/cluster_binding` 用对应 alias 在该集群写入 `observability-cluster-binding`。
- `make terraform-check` 执行 `terraform fmt -check`、`terraform init -backend=false` 和 `terraform validate`。`make config-check` 会调用它。

Terraform 不能把不同的 provider alias 传给 `for_each` 的不同实例。所以 agent 清单的下发用每个实例自己的 kubeconfig 调 `kubectl`，Kubernetes provider 的 alias 用来管理中心集群的 Grafana Secret 和每个示例工作负载集群的 binding ConfigMap。增加集群时不用复制 Deployment。

## 4. Agent 到不了中心端点

上面的 DNS 假设意味着：工作负载集群里的 Alloy 会去连本集群的 `prometheus:9090`，而那里没有 remote write receiver。Collector 的 OTLP 导出、Tempo 的 span metrics、Pyroscope 的 OTLP 也一样。Profile 的 HTTP 推送在 demo 里是 `PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040`，出了本集群就没有这个名字。

没有任何变量把中心 URL 注入 agent。改地址要同时改 Alloy 两份文件和 Collector 一份文件。

这次改了什么：

- 端点集中在 ConfigMap `observability-endpoints`（`deploy/kubernetes/base/endpoints.yaml`）。键是 `CLUSTER_NAME`、`PROMETHEUS_REMOTE_WRITE_URL`、`LOKI_PUSH_URL`、`LOKI_OTLP_ENDPOINT`、`TEMPO_OTLP_ENDPOINT`、`PYROSCOPE_OTLP_ENDPOINT`、`PYROSCOPE_HTTP_URL`。
- Compose 在 `deploy/docker-compose/docker-compose.yml` 里把同一组变量设为 Docker DNS，`CLUSTER_NAME=local`。
- 工作负载集群的 ConfigMap 由 `deploy/terraform/modules/cluster_agent` 按 map 条目写入。示例 URL 使用保留域名 `example.invalid`，不是真实地址。

## 5. 密钥

Grafana 管理员密码在 Compose 里来自 `GF_SECURITY_ADMIN_PASSWORD`（`deploy/docker-compose/.env` 被 gitignore）。Kubernetes 的 `deploy/kubernetes/base/grafana.yaml` 引用 Secret `grafana-admin`，README 要求用 kubectl 手工创建，仓库里没有这份 Secret。这是对的，但没有 Terraform 可以重复创建它，也没有说明 state 里会不会出现密码。

Remote write、Loki、Tempo、Pyroscope 都没有认证。Postgres 是 `trust`，连接串里没有密码。这些都不该在多集群开通时被写进 git。

这次改了什么：

- `grafana_admin_password` 是 sensitive 变量，默认 `null`。只有显式设置时，`modules/central` 才创建 Secret `grafana-admin`。`terraform.tfvars.example` 不写密码。
- kubeconfig 只出现在变量里。`terraform.tfvars` 和 `*.tfstate` 被 gitignore。`backend.tf.example` 说明远端状态要加密，因为 state 可能含有 Grafana 密码。
- 没有把 bearer token 写进 Alloy 或 Collector。当前导出仍是明文 HTTP（`tls.insecure: true`）。鉴权网关仍然是后续工作，不在这次提交里假装已经做完。

## 6. 标签基数

已经做对的部分要保留，不能在加 `cluster` 时退回去：

- `config/otel-collector/config.yaml` 删除 `user.id`、`order.id`、`customer.id`、`enduser.id` 和原始 URL。
- `config/prometheus/prometheus.yml` 丢掉 `redis_key_.*`。
- `config/alloy/config.k8s.alloy` 丢掉 cAdvisor 的 `id`、`container_id`、`image_id`。
- Pod 日志标签是 `namespace`、`pod`、`container`、`app`，没有 pod uid。

风险是：如果远程写入时用 Pod IP 或 Pod uid 当 `instance`，每个 Pod 重启都会新增序列。`service.instance.id` 已经在 Loki 索引里，值是主机名，基数等于副本数，不是请求数。这次没有把它拿掉，也没有新增 pod uid 或用户 id。

这次改了什么：

- `cluster` 只允许一个集群一个值。Terraform 用 DNS label 校验 map 的键。
- 工作负载 node-exporter 的 `instance` 是节点名，不是 Pod IP。
- 记录规则的 `by` 子句增加 `cluster`，不增加 uid。

## 7. 文档缺口

`docs/` 有架构、接入、处理、倾斜、排障、SLO、指标目录。没有多集群文档，没有 Terraform 文档。`docs/data-skew.md` 把 `external_labels.cluster` 写成 `observability`，并说没有多租户，没有描述一个集群把中心存储撑满时其它集群看起来怎样。README 明确说不做多集群。

这次改了什么：

- 本文记录问题和对应改动。
- 新增 `docs/multi-cluster.md` 和 `deploy/terraform/README.md`。
- README、`docs/architecture.md`、`docs/onboarding.md`、`docs/data-skew.md`、`docs/metrics-catalog.md` 改成和当前文件一致的端口、变量名和路径。

## 8. 还不是多业务平台

上一轮做完之后，仓库能把多个集群的采集送到一套中心栈，但被观察的仍然是一个 demo 服务。`examples/demo-app` 的路由和 `business_payments_total` 是唯一的业务。记录规则 `sum by (cluster, service_name)` 一旦出现第二个业务线或第二个企业客户，就会把它们加在一起。Loki `auth_enabled: false`，Tempo 没有 `multitenancy_enabled`，日志和链路只靠标签混在一个 org 里。Grafana 只有一套 `loki` / `tempo` 数据源。没有租户允许表，也没有「加一个企业客户是改地图再 apply」的路径。这还不叫同时覆盖 ToB 和 ToC、跨多个集群的企业级可观测性。

这次改了什么：

- `config/tenancy.yaml` 是业务线、租户、服务和集群落点的唯一目录。ToC 有 `toc-api` 与 `toc-checkout`，合成租户 `consumer`。ToB 有 `tob-admin` 与 `tob-billing`，允许表是 `acme` 和 `northwind`。
- `scripts/render_tenancy.py` 从这份地图生成 Collector 的 `X-Scope-OrgID` 路由、Grafana 按 org 的数据源、`tenancy.yml` 规则、Compose 业务进程、Kubernetes 工作负载和 ToB 仪表盘。`make config-check` 会比对，防止手改生成物。
- Loki `auth_enabled: true`，Tempo `multitenancy_enabled: true`。org 是 `toc`、`tob-acme`、`tob-northwind`、`platform`、`rejected`。不在允许表里的租户字符串变成常量 `rejected`，不会变成新的 org 或新的指标标签。
- Prometheus 仍是标签隔离，没有假装接了 Mimir。记录规则和告警保留 `cluster`、`tenant`、`business_line`。`toc:http_requests:rate5m` 不会计入 ToB 序列。`promtool test rules` 覆盖了这一点，也覆盖了 `acme` 与 `northwind` 不会加成一条线。
- Compose 在 `local` 上跑 ToC 两个服务和 ToB 租户 `acme`。`northwind` 在目录和清单里，副本数为 0。
- Terraform 读同一份 yaml，plan 时校验 org id。增加租户不是复制 Deployment。provider alias 仍然不能放进 `for_each`，文档继续这么写。
- 说明在 `docs/tenancy.md`。

还没有做的：中心进程仍是单副本本地盘；remote write、Loki、Tempo 前面没有鉴权网关；Pyroscope 只靠标签，不靠 org 头；Prometheus 没有换成 Mimir。这些都不要在 README 里写成已经完成。
