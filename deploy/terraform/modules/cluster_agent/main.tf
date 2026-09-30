locals {
  repo_root = abspath("${path.module}/../../../..")
  checksum = sha256(join("", concat(
    [filesha256("${local.repo_root}/deploy/terraform/scripts/kubectl-apply.sh")],
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

resource "terraform_data" "agent" {
  input = {
    kubeconfig         = var.kubeconfig
    kube_context       = var.kube_context
    cluster_name       = var.cluster_name
    repo_root          = local.repo_root
    checksum           = local.checksum
    prometheus         = var.prometheus_remote_write_url
    loki_push          = var.loki_push_url
    loki_otlp          = var.loki_otlp_endpoint
    tempo              = var.tempo_otlp_endpoint
    pyroscope          = var.pyroscope_otlp_endpoint
    pyroscope_http     = var.pyroscope_http_url
    collector_replicas = var.collector_replicas
    ingest_token       = var.ingest_token
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
      WORKLOAD_COLLECTOR_REPLICAS           = tostring(self.input.collector_replicas)
      INGEST_TOKEN                          = self.input.ingest_token == null ? "" : self.input.ingest_token
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" delete"
    environment = {
      KUBECONFIG       = self.input.kubeconfig
      KUBE_CONTEXT     = self.input.kube_context
      KUSTOMIZE_PATH   = "${self.input.repo_root}/deploy/kubernetes/agent"
      DELETE_ENDPOINTS = "true"
    }
  }
}
