# Terraform

Terraform 管理两件事：中心集群上的可观测栈，以及每个工作负载集群上的采集 agent。清单仍是 `config/` 和 `deploy/kubernetes` 里的 YAML。Kustomize 把它们渲染出来，`deploy/terraform/scripts/kubectl-apply.sh` 用指定的 kubeconfig 执行 `kubectl apply`。不要另抄一份 Deployment。

Kubernetes provider 钉在 `hashicorp/kubernetes` `2.38.0`。Terraform CLI 需要 `>= 1.6.0`。校验用的是本机的 1.14.3，不要求一定是这个补丁版本。

## 目录

| 路径 | 作用 |
| --- | --- |
| `modules/central` | 对 `deploy/kubernetes/overlays/dev` 或 `prod` 做 apply。可选创建 Secret `grafana-admin` |
| `modules/cluster_agent` | 对 `deploy/kubernetes/agent` 做 apply，并写入 ConfigMap `observability-endpoints` |
| `modules/cluster_binding` | 用 Kubernetes provider 在该集群写入 ConfigMap `observability-cluster-binding` |
| `stacks/platform` | 示例：一个中心栈，加上 `workload_clusters` 的 `for_each` |
| `stacks/platform/terraform.tfvars.example` | 变量样例。复制成 `terraform.tfvars`，该文件被 gitignore |
| `stacks/platform/backend.tf.example` | 远端状态样例，Terraform 不会加载它 |
| `scripts/kubectl-apply.sh` | `apply` 或 `delete`。需要本机有 `kubectl` 和 `kustomize` |

## 租户目录

业务线和租户不在 tfvars 里再抄一份。`stacks/platform/tenancy.tf` 读取仓库根的 `config/tenancy.yaml`。增加一个 ToB 租户：

1. 改 yaml 里的 `business_lines.tob.tenants`，`org_id` 写成 `tob-<id>`。
2. 把同一个 id 写进 `examples/demo-app/src/demo_app/identity.py` 的 `TOB_TENANTS`。
3. `make render-tenancy`，然后 `make config-check`。
4. `terraform apply`。生成的 Collector、数据源、规则和工作负载会随中心栈的 Kustomize 一起应用。

`terraform plan` 会检查租户 id 是 DNS 标签，并且 org id 等于 `tob-<id>`。输出 `tob_tenant_ids` 和 `tenancy_org_ids`。

这仍然不是「一个租户一个 Kubernetes provider」。租户是中心栈里的数据。`for_each` 不能给每个实例换 provider alias，所以工作负载集群的 agent 继续用各自的 kubeconfig 调 `kubectl`。增加集群和增加租户是两件不同的事。

## 为什么 YAML 还在

Compose 用 bind mount 读取 `config/`。Kustomize 的 `configMapGenerator` 也指向这些文件。如果 Terraform 再用 template 生成第二份 Prometheus 配置，两边会分叉。所以 Terraform 不渲染业务配置，只决定哪个 kubeconfig、哪个集群名、哪组中心 URL。

中心栈的 `cluster` 标签在 `config/prometheus/prometheus.yml` 里钉成 `local`，和 Compose 相同。变量 `central_cluster_name` 因此只接受 `local`。要改这个名字，必须同时改 Prometheus 的 `replacement`、`deploy/kubernetes/base/endpoints.yaml` 和这个变量。

## Provider alias 和 for_each

`stacks/platform/providers.tf` 声明三个 alias：

| alias | kubeconfig |
| --- | --- |
| `kubernetes.central` | `var.central_kubeconfig` |
| `kubernetes.prod_a` | `var.workload_clusters["prod-a"].kubeconfig` |
| `kubernetes.prod_b` | `var.workload_clusters["prod-b"].kubeconfig` |

`module "central"` 使用 `kubernetes.central`。`module "binding_prod_a"` 和 `binding_prod_b` 使用对应的工作负载 alias，在命名空间 `observability` 里创建 `observability-cluster-binding`。

`module "workload"` 使用 `for_each = local.enabled_workload_clusters`。Terraform 不能给 `for_each` 的每个实例传递不同的 provider alias，所以 agent 清单不走 Kubernetes provider，而由模块里的 `terraform_data` 调用 `kubectl --kubeconfig`。kubeconfig 路径来自 map。增加集群时，DaemonSet 和 Collector 不用复制。

示例要求 map 里始终有键 `prod-a` 和 `prod-b`，因为 provider 块引用了它们。不想要其中一个集群时，把 `enabled` 设为 `false`，不要删掉键。

## 初始化、计划、应用

在有 kubeconfig、kubectl、kustomize 的机器上：

```bash
cd deploy/terraform/stacks/platform
cp terraform.tfvars.example terraform.tfvars
# 把 kubeconfig 路径改成你机器上的文件。不要提交 terraform.tfvars。
terraform init
terraform plan
terraform apply
```

`terraform.tfvars.example` 里的 URL 主机是 `prometheus.central.example.invalid` 等。`.invalid` 是保留域名。plan 可以展示变更，apply 在 kubeconfig 指向真实集群且网络可达之前不会把数据送进中心栈。

Grafana 密码不要写进 tfvars。需要 Terraform 创建 Secret 时：

```bash
export TF_VAR_grafana_admin_password='用你自己的密码替换'
terraform apply
```

不设置这个变量时，Secret 不会被创建。中心 Grafana 的 Deployment 仍然引用 `grafana-admin`，Pod 会停在 `CreateContainerConfigError`，直到你用 kubectl 创建它。这和原来的 README 一样。

没有集群时只做静态检查：

```bash
make terraform-check
```

它执行：

```bash
terraform fmt -check -recursive -diff deploy/terraform
terraform -chdir=deploy/terraform/stacks/platform init -backend=false -input=false
terraform -chdir=deploy/terraform/stacks/platform validate
```

`validate` 不连接 API server，也不读取 kubeconfig 文件。`make config-check` 会调用这段检查。

## 状态

默认是本地状态文件 `terraform.tfstate`，已被 gitignore。如果设置了 `grafana_admin_password`，密码会出现在 state 里。

要换远端状态，参考 `backend.tf.example`，复制成 `backend.tf` 后自行填写 bucket。不要提交带账号或密钥的 `backend.tf`。远端状态需要加密。换 backend 之后重新 `terraform init`。

## 每个集群的 kubeconfig

每个 alias 一个文件或一个 context。示例：

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

`context` 可以省略，这时使用该 kubeconfig 的当前 context。不要把这些文件放进仓库。

## 只销毁一个工作负载集群

把那个集群的 `enabled` 设为 `false`，然后 `terraform apply`。

`prod-a` 的 `enabled = false` 会：

- 从 `module.workload` 的 `for_each` 里去掉 `prod-a`，销毁时对该 kubeconfig 执行 `kubectl delete`（agent 清单和 `observability-endpoints`）
- 把 `module.binding_prod_a` 的 count 设为 0，删掉 `observability-cluster-binding`

`prod-b` 和中心栈不动。键 `prod-a` 要留在 map 里，否则 `kubernetes.prod_a` 的 `config_path` 会在 plan 时直接报错，销毁进行不下去。

销毁中心栈是 `terraform destroy`，或者对 `module.central` 做针对性销毁。那会删掉中心 overlay 里的资源。工作负载集群仍会尝试 remote write，直到它们自己被禁用。

## 增加第三个集群

假设新集群叫 `prod-c`。

1. 在 `terraform.tfvars` 的 `workload_clusters` 增加 `prod-c`，字段和 `prod-a` 相同：`kubeconfig`、可选 `context`、五条中心 URL。`enabled` 默认 true。键必须是 DNS label，它会变成标签 `cluster="prod-c"`。
2. 在 `stacks/platform/providers.tf` 增加 alias，kubeconfig 取自 `var.workload_clusters["prod-c"].kubeconfig`。写法照 `prod_a`。
3. 在 `stacks/platform/main.tf` 增加 `module "binding_prod_c"`，`source` 仍是 `../../modules/cluster_binding`，`providers` 指向新 alias，`cluster_name = "prod-c"`，`enabled = var.workload_clusters["prod-c"].enabled`，`depends_on = [module.workload]`。
4. `module "workload"` 的 `for_each` 会自动包含 `prod-c`，不需要复制 `deploy/kubernetes` 里的 YAML。
5. 在 `variables.tf` 的校验里，如果希望缺键就失败，把 `prod-c` 加进 `contains(keys(...))` 列表。示例校验目前只强制 `prod-a` 和 `prod-b`。

`terraform apply` 之后，中心 Grafana 把变量 `cluster` 选成 `prod-c`。看不到数据时按 [docs/multi-cluster.md](../../docs/multi-cluster.md) 的顺序查 ConfigMap、Alloy 日志和 `count by (cluster) (up)`。

## 变量

中心：

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `central_kubeconfig` | 无，必填 | 中心 kubeconfig 路径 |
| `central_kube_context` | `""` | 空则用文件当前 context |
| `central_overlay` | `dev` | `dev` 或 `prod` |
| `central_cluster_name` | `local` | 必须是 `local` |
| `grafana_admin_user` | `admin` | Secret 里的用户名 |
| `grafana_admin_password` | `null` | sensitive。null 表示不创建 Secret |

工作负载 map 的每个对象：

| 字段 | 含义 |
| --- | --- |
| `enabled` | 默认 true。false 只销毁这一项 |
| `kubeconfig` | 该集群的 kubeconfig |
| `context` | 可选 |
| `prometheus_remote_write_url` | 中心 `/api/v1/write` |
| `loki_push_url` | 中心 `/loki/api/v1/push` |
| `loki_otlp_endpoint` | 中心 `/otlp` |
| `tempo_otlp_endpoint` | `host:4317`，不带 `http://` |
| `pyroscope_otlp_endpoint` | `host:4040` |
| `pyroscope_http_url` | SDK 用的 `http://host:4040` |

输出 `workload_clusters` 是当前会 apply 的集群名。`workload_remote_write_urls` 是它们的 remote write 地址。
