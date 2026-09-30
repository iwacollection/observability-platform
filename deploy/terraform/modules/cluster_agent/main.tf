locals {
  repo_root           = abspath("${path.module}/../../../..")
  managed_resources   = yamldecode(file("${path.module}/managed_resources.yaml"))
  required_components = toset(local.managed_resources.required_components)
  managed_ids = sort(flatten([
    for component, items in local.managed_resources.components : [
      for item in items : "${component}:${item.kind}/${item.name}"
    ]
  ]))
  endpoints_configmap_name = one([
    for item in local.managed_resources.components.endpoints : item.name
    if item.kind == "ConfigMap"
  ])
  ingest_secret_name = one([
    for item in local.managed_resources.components.secrets : item.name
    if item.kind == "Secret" && item.name == "ingest-auth"
  ])
  checksum = sha256(join("", concat(
    [filesha256("${local.repo_root}/deploy/terraform/scripts/kubectl-apply.sh")],
    [filesha256("${path.module}/managed_resources.yaml")],
    [for f in sort(fileset("${local.repo_root}/config/alloy", "*.alloy")) : filesha256("${local.repo_root}/config/alloy/${f}")],
    [for f in sort(fileset("${local.repo_root}/config/otel-collector", "**")) : filesha256("${local.repo_root}/config/otel-collector/${f}")],
    [for f in sort(fileset("${local.repo_root}/deploy/kubernetes/agent", "**")) : filesha256("${local.repo_root}/deploy/kubernetes/agent/${f}")],
    [
      filesha256("${local.repo_root}/deploy/kubernetes/base/alloy.yaml"),
      filesha256("${local.repo_root}/deploy/kubernetes/base/otel-collector.yaml"),
      filesha256("${local.repo_root}/deploy/kubernetes/base/node-exporter.yaml"),
      filesha256("${local.repo_root}/deploy/kubernetes/base/kube-state-metrics.yaml"),
      filesha256("${local.repo_root}/deploy/kubernetes/base/namespace.yaml"),
      filesha256("${local.repo_root}/deploy/kubernetes/base/networkpolicy.yaml"),
    ],
  )))
}

# Destroy hook. Replacing agent_apply re-runs kubectl apply and does not
# delete the namespace. for_each cannot switch provider aliases, so this
# module keeps using the kubeconfig from the map.
resource "terraform_data" "agent" {
  input = {
    kubeconfig   = var.kubeconfig
    kube_context = var.kube_context
    repo_root    = local.repo_root
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" delete"
    environment = {
      KUBECONFIG           = self.input.kubeconfig
      KUBE_CONTEXT         = self.input.kube_context
      KUSTOMIZE_PATH       = "${self.input.repo_root}/deploy/kubernetes/agent"
      DELETE_ENDPOINTS     = "true"
      DELETE_INGEST_SECRET = "true"
    }
  }
}

resource "terraform_data" "agent_apply" {
  depends_on = [terraform_data.agent]

  triggers_replace = {
    checksum           = local.checksum
    cluster_name       = var.cluster_name
    kubeconfig         = var.kubeconfig
    kube_context       = var.kube_context
    prometheus         = var.prometheus_remote_write_url
    loki_push          = var.loki_push_url
    loki_otlp          = var.loki_otlp_endpoint
    tempo              = var.tempo_otlp_endpoint
    pyroscope          = var.pyroscope_otlp_endpoint
    pyroscope_http     = var.pyroscope_http_url
    collector_replicas = tostring(var.collector_replicas)
    managed_ids        = join(",", local.managed_ids)
    tenant             = var.tenant
    business_line      = var.business_line
    org_id             = var.org_id
    # Sensitive. A new token re-applies Secret ingest-auth on this cluster.
    ingest_token_sha = sha256(coalesce(var.ingest_token, ""))
  }

  input = {
    kubeconfig          = var.kubeconfig
    kube_context        = var.kube_context
    cluster_name        = var.cluster_name
    repo_root           = local.repo_root
    prometheus          = var.prometheus_remote_write_url
    loki_push           = var.loki_push_url
    loki_otlp           = var.loki_otlp_endpoint
    tempo               = var.tempo_otlp_endpoint
    pyroscope           = var.pyroscope_otlp_endpoint
    pyroscope_http      = var.pyroscope_http_url
    collector_replicas  = tostring(var.collector_replicas)
    ingest_token        = coalesce(var.ingest_token, "")
    tenant              = var.tenant
    business_line       = var.business_line
    org_id              = var.org_id
    endpoints_configmap = local.endpoints_configmap_name
    ingest_secret       = local.ingest_secret_name
  }

  provisioner "local-exec" {
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" apply"
    environment = {
      KUBECONFIG                            = self.input.kubeconfig
      KUBE_CONTEXT                          = self.input.kube_context
      KUSTOMIZE_PATH                        = "${self.input.repo_root}/deploy/kubernetes/agent"
      ENDPOINTS_CLUSTER_NAME                = self.input.cluster_name
      ENDPOINTS_PROMETHEUS_REMOTE_WRITE_URL = self.input.prometheus
      ENDPOINTS_LOKI_PUSH_URL               = self.input.loki_push
      ENDPOINTS_LOKI_OTLP_ENDPOINT          = self.input.loki_otlp
      ENDPOINTS_TEMPO_OTLP_ENDPOINT         = self.input.tempo
      ENDPOINTS_PYROSCOPE_OTLP_ENDPOINT     = self.input.pyroscope
      ENDPOINTS_PYROSCOPE_HTTP_URL          = self.input.pyroscope_http
      ENDPOINTS_TENANT                      = self.input.tenant
      ENDPOINTS_BUSINESS_LINE               = self.input.business_line
      ENDPOINTS_ORG_ID                      = self.input.org_id
      WORKLOAD_COLLECTOR_REPLICAS           = self.input.collector_replicas
      INGEST_TOKEN                          = self.input.ingest_token
      INGEST_SECRET_MODE                    = "script"
    }
  }

  lifecycle {
    precondition {
      condition     = length(setsubtract(local.required_components, toset(keys(local.managed_resources.components)))) == 0
      error_message = "cluster_agent managed_resources.yaml is missing a required component."
    }
    precondition {
      condition     = !var.require_ingest_token || (var.ingest_token != null && var.ingest_token != "")
      error_message = "Prod central requires TF_VAR_ingest_token so workload clusters get Secret ingest-auth from terraform apply."
    }
  }
}
