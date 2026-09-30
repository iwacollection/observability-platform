provider "kubernetes" {
  alias          = "central"
  config_path    = var.central_kubeconfig
  config_context = var.central_kube_context != "" ? var.central_kube_context : null
}
