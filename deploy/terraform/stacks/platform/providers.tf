provider "kubernetes" {
  alias          = "central"
  config_path    = var.central_kubeconfig
  config_context = var.central_kube_context != "" ? var.central_kube_context : null
}

provider "kubernetes" {
  alias          = "prod_a"
  config_path    = var.workload_clusters["prod-a"].kubeconfig
  config_context = try(var.workload_clusters["prod-a"].context, null) != null && var.workload_clusters["prod-a"].context != "" ? var.workload_clusters["prod-a"].context : null
}

provider "kubernetes" {
  alias          = "prod_b"
  config_path    = var.workload_clusters["prod-b"].kubeconfig
  config_context = try(var.workload_clusters["prod-b"].context, null) != null && var.workload_clusters["prod-b"].context != "" ? var.workload_clusters["prod-b"].context : null
}
