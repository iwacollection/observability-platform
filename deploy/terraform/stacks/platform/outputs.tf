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

output "tenancy_org_ids" {
  value       = local.tenancy_org_ids
  description = "Loki and Tempo X-Scope-OrgID values from config/tenancy.yaml."
}

output "tob_tenant_ids" {
  value       = local.tob_tenant_ids
  description = "Bounded ToB tenant allow-list. Not customer user ids."
}

output "workload_remote_write_urls" {
  value = {
    for name, agent in module.workload : name => agent.prometheus_remote_write_url
  }
  description = "Central remote-write URL configured for each applied workload cluster."
}

output "central_managed_components" {
  value       = module.central.managed_component_names
  description = "Components the central module declares and terraform apply installs."
}

output "generated_workload_names" {
  value       = local.generated_workload_names
  description = "ToC and ToB workload names from config/tenancy.yaml, excluding demo-app."
}
