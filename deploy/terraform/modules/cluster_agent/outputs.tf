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

output "managed_component_names" {
  value       = sort(tolist(local.required_components))
  description = "Agent components this module declares."
}

output "ingest_secret_managed" {
  value       = var.ingest_token != null && var.ingest_token != ""
  description = "True when terraform apply writes Secret ingest-auth on this cluster."
}
