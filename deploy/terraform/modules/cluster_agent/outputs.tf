output "cluster_name" {
  value       = var.cluster_name
  description = "cluster label this agent writes."
}

output "namespace" {
  value       = "observability"
  description = "Namespace the agent manifests use."
}

output "prometheus_remote_write_url" {
  value       = var.prometheus_remote_write_url
  description = "Central remote-write URL configured for this cluster."
}
