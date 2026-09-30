# Name contract for ConfigMap observability-cluster-binding.
# The platform stack does not instantiate this module once per cluster.
# Provider aliases cannot be passed through for_each, so kubectl-apply.sh
# writes the ConfigMap from the workload_clusters map entry. Adding a
# cluster is that map entry. Do not add a provider alias for it.

locals {
  managed_resources = yamldecode(file("${path.module}/managed_resources.yaml"))
  binding_name      = local.managed_resources.components["cluster-binding"][0].name
}

output "binding_name" {
  value = local.binding_name
}
