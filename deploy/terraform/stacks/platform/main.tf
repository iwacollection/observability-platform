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

  kubeconfig             = var.central_kubeconfig
  kube_context           = var.central_kube_context
  overlay                = var.central_overlay
  cluster_name           = var.central_cluster_name
  grafana_admin_user     = var.grafana_admin_user
  grafana_admin_password = var.grafana_admin_password
  ingest_token           = var.ingest_token
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
}

module "binding_prod_a" {
  source = "../../modules/cluster_binding"

  providers = {
    kubernetes.this = kubernetes.prod_a
  }

  cluster_name = "prod-a"
  enabled      = var.workload_clusters["prod-a"].enabled

  depends_on = [module.workload]
}

module "binding_prod_b" {
  source = "../../modules/cluster_binding"

  providers = {
    kubernetes.this = kubernetes.prod_b
  }

  cluster_name = "prod-b"
  enabled      = var.workload_clusters["prod-b"].enabled

  depends_on = [module.workload]
}
