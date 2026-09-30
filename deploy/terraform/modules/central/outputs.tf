output "overlay" {
  value       = var.overlay
  description = "Kustomize overlay applied to the central cluster."
}

output "cluster_name" {
  value       = var.cluster_name
  description = "cluster label stored for the central stack."
}

output "namespace" {
  value       = "observability"
  description = "Namespace that holds the central LGTM stack."
}

output "grafana_secret_managed" {
  value       = var.grafana_admin_password != null
  description = "True when Terraform created the grafana-admin Secret."
}

output "ingest_secret_managed" {
  value       = var.overlay == "prod"
  description = "True when the Kubernetes provider creates Secret ingest-auth. Dev uses the overlay placeholder instead."
}

output "managed_component_names" {
  value       = sort(tolist(local.required_components))
  description = "Platform components this module declares. The coverage check compares them to kustomize output."
}
