provider "grafana" {
  url  = var.grafana_url
  auth = local.grafana_auth_value
}
