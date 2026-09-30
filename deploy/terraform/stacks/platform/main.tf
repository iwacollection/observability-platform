locals {
  enabled_workload_clusters = {
    for name, cluster in var.workload_clusters : name => cluster
    if cluster.enabled
  }
}

module "central" {
  source = "../../modules/central"

  providers = {
    kubernetes.this = kubernetes.central
  }

  kubeconfig               = var.central_kubeconfig
  kube_context             = var.central_kube_context
  overlay                  = var.central_overlay
  cluster_name             = var.central_cluster_name
  grafana_admin_user       = var.grafana_admin_user
  grafana_admin_password   = var.grafana_admin_password
  ingest_token             = var.ingest_token
  alert_webhook_url        = var.alert_webhook_url
  generated_workload_names = local.generated_workload_names
}

module "workload" {
  source   = "../../modules/cluster_agent"
  for_each = local.enabled_workload_clusters

  cluster_name                = each.key
  kubeconfig                  = each.value.kubeconfig
  kube_context                = coalesce(each.value.context, "")
  prometheus_remote_write_url = each.value.prometheus_remote_write_url
  loki_push_url               = each.value.loki_push_url
  loki_otlp_endpoint          = each.value.loki_otlp_endpoint
  tempo_otlp_endpoint         = each.value.tempo_otlp_endpoint
  pyroscope_otlp_endpoint     = each.value.pyroscope_otlp_endpoint
  pyroscope_http_url          = each.value.pyroscope_http_url
  collector_replicas          = var.workload_collector_replicas
  ingest_token                = var.ingest_token
  require_ingest_token        = var.central_overlay == "prod"
  exporter_tls_insecure       = each.value.exporter_tls_insecure
  install_demo_workloads      = false
}
