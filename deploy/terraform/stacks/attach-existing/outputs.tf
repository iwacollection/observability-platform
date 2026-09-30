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
  description = "Grafana unified alerting rules for this business line. They inline tenancy.yml and do not create recording-rule names on the remote Prometheus."
}

output "prometheus_tenancy_rules" {
  value       = file(local.rules_file)
  description = "config/prometheus/rules/tenancy.yml. Codified artifact for this repo's Prometheus. Not uploaded: Prometheus has no rules API this stack can call without a live server. stacks/platform already mounts this file. Recording-rule names inside it are not created by Grafana."
}

output "prometheus_tenancy_rules_sha256" {
  value       = filesha256(local.rules_file)
  description = "sha256 of config/prometheus/rules/tenancy.yml."
}

output "recording_rule_names" {
  value       = local.grafana_line_alerts.recording_rule_names
  description = "Recording-rule names from tenancy.yml. They are not created on the remote Prometheus."
}

output "recording_rules_created_remotely" {
  value       = false
  description = "Always false. Grafana evaluates the inlined expressions. This stack does not create toc:payments:failure_ratio5m or the other recording-rule names on the remote Prometheus."
}

output "existing_prometheus_is_repo" {
  value       = var.existing_prometheus_is_repo
  description = "When true, the existing Prometheus is this repo's binary and already loads prometheus_tenancy_rules via stacks/platform. This output does not perform an upload."
}

output "install_demo_workloads" {
  value       = var.install_demo_workloads
  description = "Whether this apply installs the generated ToC and ToB demo workloads. Default false."
}

output "exporter_tls_insecure" {
  value       = var.exporter_tls_insecure
  description = "Whether collector OTLP exporters to Loki, Tempo, and Pyroscope disable TLS. Default false."
}
