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

output "alert_paging_enabled" {
  value       = var.alert_webhook_url != null && var.alert_webhook_url != ""
  description = "True when TF_VAR_alert_webhook_url is set. The URL itself is not an output."
}

output "managed_component_names" {
  value       = sort(tolist(local.required_components))
  description = "Platform components this module declares. The coverage check compares them to kustomize output."
}
