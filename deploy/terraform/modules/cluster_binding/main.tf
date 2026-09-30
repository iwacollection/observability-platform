resource "kubernetes_config_map_v1" "binding" {
  provider = kubernetes.this
  count    = var.enabled ? 1 : 0

  metadata {
    name      = "observability-cluster-binding"
    namespace = "observability"
    labels = {
      "app.kubernetes.io/part-of"      = "observability-platform"
      "observability.platform/cluster" = var.cluster_name
    }
  }

  data = {
    cluster    = var.cluster_name
    managed_by = "terraform-kubernetes-provider"
  }
}
