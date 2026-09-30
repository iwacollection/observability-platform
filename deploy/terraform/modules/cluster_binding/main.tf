locals {
  managed_resources = yamldecode(file("${path.module}/managed_resources.yaml"))
  binding_name      = local.managed_resources.components["cluster-binding"][0].name
}

resource "kubernetes_config_map_v1" "binding" {
  provider = kubernetes.this
  count    = var.enabled ? 1 : 0

  metadata {
    name      = local.binding_name
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
