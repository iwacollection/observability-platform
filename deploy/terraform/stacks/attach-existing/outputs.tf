output "creates_backends" {
  value       = false
  description = "This stack does not create Prometheus, Loki, Tempo, Pyroscope, or Grafana."
}

output "cluster_name" {
  value       = module.agent.cluster_name
  description = "cluster label the agent writes."
}

output "business_line" {
  value       = module.agent.business_line
  description = "business_line label the agent writes."
}

output "tenant" {
  value       = module.agent.tenant
  description = "tenant label the agent writes."
}

output "org_id" {
  value       = module.agent.org_id
  description = "X-Scope-OrgID the agent and the Grafana datasources use."
}

output "dashboard_uid" {
  value       = local.dashboard_uid
  description = "Grafana dashboard uid selected by business_line. toc-line or tob-line."
}

output "dashboard_json_path" {
  value       = local.dashboard_json_path
  description = "Existing dashboard JSON uploaded when manage_grafana is true."
}

output "prometheus_remote_write_url" {
  value       = module.agent.prometheus_remote_write_url
  description = "Existing Prometheus remote-write URL configured on the agent."
}

output "manage_grafana" {
  value       = var.manage_grafana
  description = "Whether this state registers datasources, the dashboard, and alert rules."
}

output "alert_rule_names" {
  value       = [for rule in local.line_alerts : rule.name]
  description = "Grafana unified alerting rules for this business line. They are not installed as Prometheus rule files."
}
