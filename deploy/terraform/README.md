# Terraform

集群里的可观测组件只通过这一条路径安装：`deploy/terraform/stacks/platform` 的 `terraform apply`。YAML 仍是清单来源，Kustomize 负责渲染。人不需要再单独 `kubectl apply` 这套栈。

本机 Docker Compose 不走 Terraform。`deploy/docker-compose/` 仍是笔记本上的入口。

Kubernetes provider 钉在 `hashicorp/kubernetes` `2.38.0`。Terraform CLI 需要 `>= 1.6.0`。

## 一条命令路径

在 `deploy/terraform/stacks/platform` 下操作。

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
```

`TF_VAR_ingest_token` 是 sensitive。

| overlay | Secret `ingest-auth` |
| --- | --- |
| `dev` | Kustomize 里已有本地占位。变量留空就不会覆盖它。这个占位不是生产口令 |
| `prod` | 必填。Kubernetes provider 创建 Secret，键是 `token`。不设置则 apply 失败 |

`deploy/kubernetes/ingest-auth.secret.example.yaml` 只说明 Secret 的形状，token 写的是 `replace-me`。它不在任何 kustomization 里。不要 kubectl apply 它来完成安装。

工作负载集群上的 Alloy 和 Collector 也读这份 Secret。中心是 prod 时，同一个 `TF_VAR_ingest_token` 会写到每个启用的工作负载集群。中心是 dev、又要让工作负载集群连上来时，把变量设成你正在用的那串口令（本地占位或你自己的值）。留空则工作负载集群没有这个 Secret，Pod 起不来。

Grafana 密码同理：没设置时不会创建 Secret `grafana-admin`，Pod 停在 `CreateContainerConfigError`。补上变量后再 apply。

`terraform plan` 和 `terraform apply` 都会加载三个 provider alias，所以 `central`、`prod-a`、`prod-b` 的 kubeconfig 文件必须存在，即使这次只改其中一个集群。没有这些文件时不要 plan。没有集群时的检查是：

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
terraform apply -target='module.workload["prod-a"]' -target=module.binding_prod_a
```

`prod-b` 把名字换成 `prod-b` 和 `module.binding_prod_b`。

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

`prod-a` 的 `enabled = false` 会删掉该 kubeconfig 上的 agent 清单、`observability-endpoints` 和 `ingest-auth`，并删掉 `observability-cluster-binding`。`prod-b` 和中心栈不动。

不要删掉键。`kubernetes.prod_a` 的 `config_path` 在 plan 时就会读它，键没了，销毁进行不下去。

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
| `modules/cluster_binding` | 用 Kubernetes provider 写入 ConfigMap `observability-cluster-binding` |
| `stacks/platform` | 一个中心栈，加上 `workload_clusters` 的 `for_each` |
| `stacks/platform/tenancy.tf` | 读取 `config/tenancy.yaml` |
| `stacks/platform/terraform.tfvars.example` | 变量样例。复制成 `terraform.tfvars`，该文件被 gitignore |
| `stacks/platform/backend.tf.example` | 远端状态样例，Terraform 不会加载它 |
| `scripts/kubectl-apply.sh` | 仅由 Terraform 的 local-exec 调用。不要手跑它来安装 |
| `scripts/check-coverage.py` | 无集群覆盖检查 |

## 为什么 YAML 还在

Compose 用 bind mount 读取 `config/`。Kustomize 的 `configMapGenerator` 也指向这些文件。Terraform 再生成第二份 Prometheus 配置，两边会分叉。所以 Terraform 不渲染业务配置，只决定哪个 kubeconfig、哪个集群名、哪组中心 URL，以及 prod 的写入口令。

中心栈的 `cluster` 标签在 `config/prometheus/prometheus.yml` 里钉成 `local`。变量 `central_cluster_name` 只接受 `local`。要改这个名字，必须同时改 Prometheus 的 `replacement`、`deploy/kubernetes/base/endpoints.yaml` 和这个变量。

清单变更会替换 `terraform_data.stack_apply`（或 `agent_apply`）并重新 apply。销毁钩子是另一个资源，配置变更不会先把整栈 `kubectl delete` 掉。`terraform destroy` 或关掉一个工作负载集群时才会删除。

## Provider alias 和 for_each

`stacks/platform/providers.tf` 声明三个 alias：

| alias | kubeconfig |
| --- | --- |
| `kubernetes.central` | `var.central_kubeconfig` |
| `kubernetes.prod_a` | `var.workload_clusters["prod-a"].kubeconfig` |
| `kubernetes.prod_b` | `var.workload_clusters["prod-b"].kubeconfig` |

`module "central"` 使用 `kubernetes.central`，用来创建 Grafana 和 prod ingest 的 Secret。`module "binding_prod_a"` 和 `binding_prod_b` 使用对应的工作负载 alias。

`module "workload"` 使用 `for_each = local.enabled_workload_clusters`。Terraform 不能给 `for_each` 的每个实例传递不同的 provider alias，所以 agent 清单不走 Kubernetes provider，而由模块里的 `terraform_data` 按该集群的 kubeconfig 调用 `kubectl`。增加集群时，DaemonSet 和 Collector 不用复制。

示例要求 map 里始终有键 `prod-a` 和 `prod-b`。不想要其中一个时，把 `enabled` 设为 `false`，不要删掉键。

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
2. 在 `stacks/platform/providers.tf` 增加 alias，kubeconfig 取自 `var.workload_clusters["prod-c"].kubeconfig`。
3. 在 `stacks/platform/main.tf` 增加 `module "binding_prod_c"`，`providers` 指向新 alias，`cluster_name = "prod-c"`，`enabled = var.workload_clusters["prod-c"].enabled`，`depends_on = [module.workload]`。
4. `module "workload"` 的 `for_each` 会包含 `prod-c`。不要复制 `deploy/kubernetes` 里的 YAML。
5. 若希望缺键就失败，把 `prod-c` 加进 `variables.tf` 的 `contains(keys(...))` 列表。示例校验目前只强制 `prod-a` 和 `prod-b`。

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
