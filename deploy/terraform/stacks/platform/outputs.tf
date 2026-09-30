output "central_cluster_name" {
  value       = module.central.cluster_name
  description = "cluster label on the central stack."
}

output "central_namespace" {
  value       = module.central.namespace
  description = "Namespace of the central LGTM stack."
}

output "central_overlay" {
  value       = module.central.overlay
  description = "Kustomize overlay used for the central stack."
}

output "workload_clusters" {
  value       = sort(keys(module.workload))
  description = "Workload clusters whose agents Terraform will apply."
}

output "workload_remote_write_urls" {
  value = {
    for name, agent in module.workload : name => agent.prometheus_remote_write_url
  }
  description = "Central remote-write URL configured for each applied workload cluster."
}
