# Terraform

有两条 Terraform 路径，加上一条不走 Terraform 的本机路径。

| 路径 | 什么时候用 |
| --- | --- |
| `deploy/terraform/stacks/platform` | 这套 Prometheus、Loki、Tempo、Pyroscope、Grafana 由我们安装。apply 会创建中心栈，再给工作负载集群装 agent |
| `deploy/terraform/stacks/attach-existing` | 指标、日志、链路、Profile 和 Grafana 已经在别处跑着。apply 只给工作负载集群装 agent，并把该业务线的数据源、仪表盘和告警登记到现有 Grafana。不会创建 Prometheus、Loki、Tempo、Pyroscope 或 Grafana |
| `deploy/docker-compose/` | 笔记本。不走 Terraform |

YAML 仍是清单来源，Kustomize 负责渲染。人不需要再单独 `kubectl apply` 这套栈。更长的说明在 [docs/attach-existing.md](../../docs/attach-existing.md)。

`stacks/platform` 的 Kubernetes provider 钉在 `hashicorp/kubernetes` `2.38.0`。`stacks/attach-existing` 的 Grafana provider 钉在 `grafana/grafana` `4.46.0`。Terraform CLI 需要 `>= 1.6.0`。

## 接到已经存在的系统

在 `deploy/terraform/stacks/attach-existing` 下操作。这一次 apply 装的是工作负载集群上的命名空间、Alloy、两个副本的 Collector、node-exporter、kube-state-metrics、NetworkPolicy、ConfigMap `observability-endpoints` 和 Secret `ingest-auth`。`manage_grafana = true` 时，还会在现有 Grafana 里登记数据源、`toc-line` 或 `tob-line` 仪表盘，以及该业务线的 Grafana 告警。

不会创建 Prometheus、Loki、Tempo、Pyroscope、Grafana。`install_demo_workloads` 默认 `false`，不装 demo。设为 `true` 时安装和中心 base 相同的生成工作负载（`demo-app.yaml` 与 `business-workloads.yaml`）。应用自己把 OTLP 打到本集群的 `otel-collector.observability.svc:4317`。

现有 Prometheus 收 remote write。本栈不上传 `config/prometheus/rules/tenancy.yml`：没有活着的 Prometheus 就没有可调用的规则 API。`terraform output prometheus_tenancy_rules` 是这份文件。`existing_prometheus_is_repo = true` 时，它已经由 `stacks/platform` 挂进 ConfigMap `prometheus-rules`。Grafana 告警展开同一批表达式。记录规则名不会在远端被创建，`recording_rules_created_remotely` 是 `false`。

`exporter_tls_insecure` 默认 `false`。Loki、Tempo、Pyroscope 的 OTLP 因此对 HTTPS 端点使用 TLS。明文端点才设 `true`。私有 CA 用 `TF_VAR_exporter_tls_ca_pem`，不要提交证书。

### init、plan、apply

```bash
cd deploy/terraform/stacks/attach-existing
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`。主机名用真实地址，样例里的 `example.invalid` 不是环境。不要写 `prometheus.observability.svc`。不要把口令写进 tfvars。

```bash
export TF_VAR_ingest_token='现有系统的写入口令'
export TF_VAR_grafana_auth='现有 Grafana 的 API token'
terraform init
terraform plan
terraform apply
```

`TF_VAR_ingest_token` 是原始口令，不是带 `Bearer ` 的整段头。Agent 和数据源的 `Authorization` 会自己加 `Bearer`。`TF_VAR_grafana_auth` 是现有 Grafana 的 API token，或 `用户名:密码`。

| 变量 | ToC | ToB acme | ToB northwind |
| --- | --- | --- | --- |
| `business_line` | `toc` | `tob` | `tob` |
| `tenant` | `consumer` | `acme` | `northwind` |
| `org_id` | `toc` | `tob-acme` | `tob-northwind` |

`org_id` 是 `X-Scope-OrgID`。`tenant` 是指标和日志上的标签。两者不是同一个字符串。

写入地址：

| 变量 | 谁用 |
| --- | --- |
| `prometheus_remote_write_url` | Agent remote write。查询地址默认去掉 `/api/v1/write` 或 `/api/v1/push` |
| `loki_push_url` | Agent 推日志。OTLP 基址默认是该 URL 的源加上 `/otlp` |
| `tempo_otlp_endpoint` | Agent 的 Tempo gRPC，`host:port`，不带 `http://` |
| `tempo_query_url` | Grafana 查 Tempo，通常是 `:3200` |
| `pyroscope_url` | HTTP 基址。OTLP gRPC 去掉 scheme，仍是同一个 host:port |
| `grafana_url` | 现有 Grafana 的 API |
| `kubeconfig` | 只指向工作负载集群 |

查询地址和写入地址不在同一台主机上时，设置 `prometheus_query_url`、`loki_query_url` 或 `loki_otlp_endpoint`。

`terraform plan` 会读 `kubeconfig`，也会连现有 Grafana。没有集群时跑 `make terraform-check`，不要 apply。

### 再加一个集群

第一个集群保持 `manage_grafana = true`，它拥有数据源、仪表盘和告警。第二个集群另开一份状态（另一个目录，或 `terraform workspace`），`cluster_name` 和 `kubeconfig` 换成新集群，URL、`business_line`、`tenant`、`org_id` 与第一个相同，`manage_grafana = false`。然后在那份状态里 `terraform init`、`terraform plan`、`terraform apply`。

两份状态都 `manage_grafana = true` 会抢同一个仪表盘 uid 和数据源 uid。

### 换成另一个 ToB 租户

`business_line` 保持 `tob`。把 `tenant` 和 `org_id` 改成目录里的另一个租户，例如 `northwind` 和 `tob-northwind`，再 `terraform apply`。Agent 改打这个租户的标签和 `X-Scope-OrgID`。ToB 仪表盘 JSON 里 acme 和 northwind 的数据源 uid 会一起登记，所以换租户不会拆掉另一个租户的数据源。

新租户必须先写进 `config/tenancy.yaml` 并 `make render-tenancy`。不在允许表里的值会被收成 `rejected`。

### 现有 Grafana 里没有数据

1. 工作负载集群里 `kubectl -n observability get pods`。Alloy 和 `otel-collector` 应该 Ready。
2. `kubectl -n observability get configmap observability-endpoints -o yaml`。`PROMETHEUS_REMOTE_WRITE_URL`、`LOKI_PUSH_URL`、`TEMPO_OTLP_ENDPOINT`、`PYROSCOPE_OTLP_ENDPOINT` 必须是现有系统，不能是 `prometheus.observability.svc`。`CLUSTER_NAME`、`TENANT`、`BUSINESS_LINE`、`ORG_ID` 与 tfvars 一致。
3. Secret `ingest-auth` 的键 `token` 必须是现有系统认的那串口令。
4. 在现有 Grafana 里打开数据源。Loki、Tempo、Pyroscope、Prometheus 的头要有 `X-Scope-OrgID`（等于 `org_id`）和 `Authorization`（`Bearer` 加口令）。ToB 面板用的 uid 是 `prometheus-tob-<tenant>` 和 `loki-tob-<tenant>`，不是只有 `prometheus`。
5. 在 Prometheus 里查 `http_server_request_duration_seconds_count{cluster="<cluster_name>",business_line="<business_line>",tenant="<tenant>"}`。标签是 `rejected` 时，先看 `tenant` 是否在 `config/tenancy.yaml`。
6. Loki 要带同一个 `X-Scope-OrgID` 查。写进了别的 org，图上会像没有数据。
7. 数据源 URL 是查询地址。把 remote write 地址填进 Grafana 会查不到。
8. Collector 日志里如果是 TLS 握手失败：看 `OTEL_EXPORTER_TLS_INSECURE`。attach 默认 `false`。明文端点把 `exporter_tls_insecure` 设为 `true`。私有 CA 用 Secret `otel-exporter-tls-ca`，不要把 PEM 写进 git。
9. 仪表盘 uid：ToC 是 `toc-line`，ToB 是 `tob-line`。右上角的集群变量要选 `cluster_name`。
10. `manage_grafana = false` 的那次 apply 不会创建数据源。数据源在第一份状态里。

## 安装我们自己的中心栈

在 `deploy/terraform/stacks/platform` 下操作。这一节会创建 Prometheus、Loki、Tempo、Pyroscope 和 Grafana。后端已经存在时不要走这里。

### 准备 kubeconfig 和口令

```bash
cd deploy/terraform/stacks/platform
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars` 里的 kubeconfig 路径和 context。每个集群一个文件。不要提交 `terraform.tfvars`，也不要把 kubeconfig 放进仓库。

口令用环境变量，不写进 tfvars，也不要写进 git：

```bash
export TF_VAR_grafana_admin_password='用你自己的密码替换'
export TF_VAR_ingest_token='用你自己的写入口令替换'
# 可选。不设置时告警留在界面里。
# export TF_VAR_alert_webhook_url='https://paging.example.internal/hooks/observability'
```

`TF_VAR_ingest_token` 是 sensitive。

| overlay | Secret `ingest-auth` |
| --- | --- |
| `dev` | Kustomize 里已有本地占位。变量留空就不会覆盖它。这个占位不是生产口令 |
| `prod` | 必填。Kubernetes provider 创建 Secret，键是 `token`。不设置则 apply 失败 |

`deploy/kubernetes/ingest-auth.secret.example.yaml` 只说明 Secret 的形状，token 写的是 `replace-me`。它不在任何 kustomization 里。不要 kubectl apply 它来完成安装。

工作负载集群上的 Alloy 和 Collector 也读这份 Secret。中心是 prod 时，同一个 `TF_VAR_ingest_token` 会写到每个启用的工作负载集群。中心是 dev、又要让工作负载集群连上来时，把变量设成你正在用的那串口令（本地占位或你自己的值）。留空则工作负载集群没有这个 Secret，Pod 起不来。

Grafana 密码同理：没设置时不会创建 Secret `grafana-admin`，Pod 停在 `CreateContainerConfigError`。补上变量后再 apply。

`terraform plan` 和 `terraform apply` 会加载中心集群的 provider alias `kubernetes.central`，所以中心 kubeconfig 必须存在。工作负载集群不声明 provider alias。`module.workload` 的 `for_each` 用每一项自己的 kubeconfig 调 `kubectl`。没有集群时的检查是：

```bash
make terraform-check
```

它会 `terraform fmt -check`、对照 Kustomize 渲染结果和模块输入、`terraform init -backend=false`、`terraform validate`。`make config-check` 会调用它。`validate` 不连接 API server。

### init

```bash
terraform init
```

默认状态是本地 `terraform.tfstate`，已被 gitignore。口令如果进了 state，远端 backend 必须加密。样例在 `backend.tf.example`，复制成 `backend.tf` 后自己填，不要提交带密钥的 backend。

### 应用中心栈

`central_overlay` 取 `dev` 或 `prod`。`central_cluster_name` 只能是 `local`。

```bash
terraform apply -target=module.central
```

这一次会装上中心集群里的全部平台组件：Prometheus、Alertmanager、Loki、Tempo、Pyroscope、Grafana、ingest 网关（挂在 Prometheus / Loki / Tempo / Pyroscope 上的 sidecar）、OTel Collector、Alloy、node-exporter、kube-state-metrics、Redis / PostgreSQL / Nginx / Kafka 和各自的 exporter、ToC / ToB 工作负载（含 `demo-app`）、命名空间 `observability`、NetworkPolicy、ConfigMap（含仪表盘和规则），以及 prod 的 Secret `ingest-auth`。dev 的占位 Secret 在 overlay 里，随同一次 apply 下去。

### 应用一个工作负载集群

```bash
terraform apply -target='module.workload["prod-a"]'
```

`prod-b` 把名字换成 `prod-b`。同一次 apply 会写下 ConfigMap `observability-cluster-binding`。

工作负载集群只装命名空间、Alloy、两个副本的 Collector、node-exporter、kube-state-metrics、NetworkPolicy、ConfigMap `observability-endpoints`，以及 Secret `ingest-auth`（变量非空时）。不装 Prometheus、Loki、Tempo、Pyroscope、Grafana。

两个都要：

```bash
terraform apply
```

### 只销毁一个工作负载集群

把那个集群的 `enabled` 设为 `false`，键留在 map 里，然后：

```bash
terraform apply
```

`prod-a` 的 `enabled = false` 会把这项移出 `for_each`，删掉该 kubeconfig 上的 agent 清单、`observability-endpoints`、`ingest-auth` 和 `observability-cluster-binding`。`prod-b` 和中心栈不动。从 map 里删掉这一项也是同一次销毁。不再需要为了 provider alias 把键留着。

销毁整个中心栈是 `terraform destroy`。那会删掉中心 overlay 里的资源。工作负载集群仍会尝试写入，直到它们自己被禁用。

### 增加一个 ToB 租户

租户不是集群，不需要新的 provider alias。

1. 改 `config/tenancy.yaml` 里的 `business_lines.tob.tenants`。`org_id` 写成 `tob-<id>`。id 是 DNS 标签，不是用户 id。
2. 把同一个 id 写进 `examples/demo-app/src/demo_app/identity.py` 的 `TOB_TENANTS`。
3. `make render-tenancy`，然后 `make config-check`。
4. `terraform apply`，或只 `-target=module.central`。

`scripts/render_tenancy.py` 会改 Collector 路由、Grafana 数据源、Prometheus 规则、Compose 进程和 Kubernetes 工作负载。`stacks/platform/tenancy.tf` 读取同一份 yaml，把除 `demo-app` 以外的 Deployment / Service 名字传给 `module.central`。`terraform apply` 把渲染结果随中心栈的 Kustomize 下发。`toc-api` 仍是已有的 `demo-app`，不会再复制一份 Deployment。

`make config-check` 会失败，如果渲染出来的对象没有出现在模块的 `managed_resources.yaml` 里，或者 `config/tenancy.yaml` 里的工作负载没有出现在 Kustomize 输出里。覆盖检查不连接集群。

## 目录

| 路径 | 作用 |
| --- | --- |
| `modules/central` | 对 `overlays/dev` 或 `prod` 做 apply。prod 时创建 Secret `ingest-auth`。可选创建 Secret `grafana-admin` |
| `modules/central/managed_resources.yaml` | 中心栈对象清单。覆盖检查的输入 |
| `modules/cluster_agent` | 对 `deploy/kubernetes/agent` 做 apply，并写入 `observability-endpoints` 和 `ingest-auth` |
| `modules/cluster_agent/managed_resources.yaml` | 工作负载集群对象清单 |
| `modules/cluster_binding` | ConfigMap `observability-cluster-binding` 的名字。实际由 `kubectl-apply.sh` 按 map 项写入 |
| `stacks/platform` | 一个中心栈，加上 `workload_clusters` 的 `for_each`。我们拥有后端 |
| `stacks/platform/tenancy.tf` | 读取 `config/tenancy.yaml` |
| `stacks/attach-existing` | 只装 agent，并把数据源、`toc-line` 或 `tob-line` 仪表盘、告警登记到已有 Grafana。不创建后端 |
| `stacks/platform/terraform.tfvars.example` | 变量样例。复制成 `terraform.tfvars`，该文件被 gitignore |
| `stacks/platform/backend.tf.example` | 远端状态样例，Terraform 不会加载它 |
| `scripts/kubectl-apply.sh` | 仅由 Terraform 的 local-exec 调用。不要手跑它来安装 |
| `scripts/check-coverage.py` | 无集群覆盖检查 |

## 为什么 YAML 还在

Compose 用 bind mount 读取 `config/`。Kustomize 的 `configMapGenerator` 也指向这些文件。Terraform 再生成第二份 Prometheus 配置，两边会分叉。所以 Terraform 不渲染业务配置，只决定哪个 kubeconfig、哪个集群名、哪组中心 URL，以及 prod 的写入口令。

中心栈的 `cluster` 标签在 `config/prometheus/prometheus.yml` 里钉成 `local`。变量 `central_cluster_name` 只接受 `local`。要改这个名字，必须同时改 Prometheus 的 `replacement`、`deploy/kubernetes/base/endpoints.yaml` 和这个变量。

清单变更会替换 `terraform_data.stack_apply`（或 `agent_apply`）并重新 apply。销毁钩子是另一个资源，配置变更不会先把整栈 `kubectl delete` 掉。`terraform destroy` 或关掉一个工作负载集群时才会删除。

## Provider alias 和 for_each

`stacks/platform/providers.tf` 只声明中心 alias：

| alias | kubeconfig |
| --- | --- |
| `kubernetes.central` | `var.central_kubeconfig` |

`module "central"` 使用 `kubernetes.central`，用来创建 Grafana 和 prod ingest 的 Secret。

`module "workload"` 使用 `for_each = local.enabled_workload_clusters`。Terraform 不能给 `for_each` 的每个实例传递不同的 provider alias，所以这里不为工作负载集群声明 alias。agent 清单和 ConfigMap `observability-cluster-binding` 由模块里的 `terraform_data` 按该集群的 kubeconfig 调用 `kubectl`。增加集群时，DaemonSet 和 Collector 不用复制。

示例 map 里有 `prod-a` 和 `prod-b`。不想要其中一个时，把 `enabled` 设为 `false`，或者从 map 里删掉这一项。

## 每个集群的 kubeconfig

```hcl
central_kubeconfig   = "~/.kube/observability-central"
central_kube_context = "central"

workload_clusters = {
  prod-a = {
    kubeconfig = "~/.kube/observability-prod-a"
    context    = "prod-a"
    # URL 见 terraform.tfvars.example
  }
}
```

`context` 可以省略，这时使用该 kubeconfig 的当前 context。示例 URL 的主机是 `prometheus.central.example.invalid`。`.invalid` 是保留域名，不是真实地址。

## 增加第三个集群

假设新集群叫 `prod-c`。

1. 在 `terraform.tfvars` 的 `workload_clusters` 增加 `prod-c`，字段和 `prod-a` 相同。`enabled` 默认 true。键必须是 DNS label，它会变成标签 `cluster="prod-c"`。
2. `module "workload"` 的 `for_each` 会包含 `prod-c`，并用该项的 kubeconfig 调 `kubectl`。不要在 `providers.tf` 里加 alias，不要复制 `deploy/kubernetes` 里的 YAML，也不要再写一个 `module "binding_prod_c"`。ConfigMap `observability-cluster-binding` 由同一次 apply 写下。

## 变量

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `central_kubeconfig` | 无，必填 | 中心 kubeconfig 路径 |
| `central_kube_context` | `""` | 空则用文件当前 context |
| `central_overlay` | `dev` | `dev` 或 `prod`。prod 要求 `TF_VAR_ingest_token` |
| `central_cluster_name` | `local` | 必须是 `local` |
| `grafana_admin_user` | `admin` | Secret 里的用户名 |
| `grafana_admin_password` | `null` | sensitive。null 表示不创建 Secret |
| `ingest_token` | `null` | sensitive。用 `TF_VAR_ingest_token` 传入 |
| `alert_webhook_url` | `null` | sensitive。用 `TF_VAR_alert_webhook_url` 传入。空则告警留在界面里 |
| `workload_collector_replicas` | `2` | 只改工作负载集群 Collector 的副本，范围 2 到 5 |

工作负载 map 的每个对象：`enabled`、`kubeconfig`、可选 `context`、`prometheus_remote_write_url`、`loki_push_url`、`loki_otlp_endpoint`、`tempo_otlp_endpoint`（`host:4317`，不带 `http://`）、`pyroscope_otlp_endpoint`、`pyroscope_http_url`。

输出 `central_managed_components` 是中心模块声明的组件。`generated_workload_names` 是从 `config/tenancy.yaml` 算出的工作负载名。`tob_tenant_ids` 和 `tenancy_org_ids` 来自同一份 yaml。

## 副本

`workload_collector_replicas` 默认 2。它只传给工作负载模块。两份 Pod 挂同一份 ConfigMap。中心栈的 Collector 保持 1。Alloy 保持 DaemonSet。

Prometheus、Loki、Tempo、Pyroscope 保持 1。它们的数据在本地盘或 emptyDir 上。再加一个副本会写两份互不相识的磁盘，不是 HA。下一步是共享对象存储，然后才能谈存储副本。

工作负载 Collector 打开了 tail sampling。两个副本各自采样。这不是链路 HA。

## 覆盖检查

`deploy/terraform/scripts/check-coverage.py` 做三件事：

1. `kustomize build` dev、prod、agent。
2. 读三个模块的 `managed_resources.yaml`，以及 `config/tenancy.yaml` 里生成的工作负载名。
3. 渲染结果里的 kind/name 必须落在这份清单里。清单里标了某个 overlay 的对象也必须出现在渲染结果里。ConfigMap 的内容哈希会被剥掉，对的是生成器的逻辑名。

prod 渲染结果里不能出现 Secret `ingest-auth`。这份 Secret 只由 `kubernetes_secret_v1.ingest_auth` 创建。dev 渲染结果里必须有占位 Secret。

漏掉 Prometheus、规则 ConfigMap、仪表盘 JSON、五层仪表盘、ingest 网关 sidecar、ToB 工作负载，检查都会失败。这个检查不需要 kubeconfig。

## 排障时的 kubectl

安装不要用。对照渲染结果或看 Pod 时可以用：

```bash
kustomize build --load-restrictor LoadRestrictionsNone deploy/kubernetes/overlays/dev
kubectl -n observability get pods
kubectl -n observability port-forward svc/grafana 3000:3000
```

`kubectl apply -k` 没有 `--load-restrictor`，会拒绝生成 ConfigMap。
