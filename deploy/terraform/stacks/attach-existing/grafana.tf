# Datasource, dashboard, and folder registration against the Grafana that
# already exists. Headers keep X-Scope-OrgID and Authorization. The dashboard
# JSON is the existing ToC or ToB file, selected by business_line.

locals {
  alert_datasource_uid = (
    var.business_line == "toc" ? "prometheus" : "prometheus-tob-${var.tenant}"
  )

  toc_datasources = {
    prometheus = {
      type       = "prometheus"
      uid        = "prometheus"
      name       = "Prometheus"
      url        = local.prometheus_query_url
      org_id     = var.org_id
      is_default = true
      json_data = jsonencode({
        timeInterval = "15s"
        httpMethod   = "POST"
        exemplarTraceIdDestinations = [{
          name          = "trace_id"
          datasourceUid = "tempo"
        }]
      })
    }
    loki = {
      type       = "loki"
      uid        = "loki"
      name       = "Loki"
      url        = local.loki_query_url
      org_id     = var.org_id
      is_default = false
      json_data = jsonencode({
        timeout = 60
        derivedFields = [{
          name            = "TraceID"
          matcherRegex    = "\"trace_id\":\"([0-9a-f]+)\""
          url             = "$${__value.raw}"
          datasourceUid   = "tempo"
          urlDisplayLabel = "View trace"
        }]
      })
    }
    tempo = {
      type       = "tempo"
      uid        = "tempo"
      name       = "Tempo"
      url        = var.tempo_query_url
      org_id     = var.org_id
      is_default = false
      json_data = jsonencode({
        httpMethod = "GET"
        tracesToLogsV2 = {
          datasourceUid   = "loki"
          filterByTraceID = true
          filterBySpanID  = false
        }
        tracesToProfiles = {
          datasourceUid = "pyroscope"
        }
        tracesToMetrics = {
          datasourceUid = "prometheus"
        }
        serviceMap = {
          datasourceUid = "prometheus"
        }
        nodeGraph = {
          enabled = true
        }
      })
    }
    pyroscope = {
      type       = "grafana-pyroscope-datasource"
      uid        = "pyroscope"
      name       = "Pyroscope"
      url        = local.pyroscope_http_url
      org_id     = var.org_id
      is_default = false
      json_data  = jsonencode({})
    }
  }

  tob_tenant_datasources = merge([
    for id in local.tob_tenant_ids : {
      "prometheus-tob-${id}" = {
        type       = "prometheus"
        uid        = "prometheus-tob-${id}"
        name       = "Prometheus tob-${id}"
        url        = local.prometheus_query_url
        org_id     = "tob-${id}"
        is_default = false
        json_data = jsonencode({
          timeInterval = "15s"
          httpMethod   = "POST"
          exemplarTraceIdDestinations = [{
            name          = "trace_id"
            datasourceUid = "tempo-tob-${id}"
          }]
        })
      }
      "loki-tob-${id}" = {
        type       = "loki"
        uid        = "loki-tob-${id}"
        name       = "Loki tob-${id}"
        url        = local.loki_query_url
        org_id     = "tob-${id}"
        is_default = false
        json_data = jsonencode({
          timeout = 60
          derivedFields = [{
            name            = "TraceID"
            matcherRegex    = "\"trace_id\":\"([0-9a-f]+)\""
            url             = "$${__value.raw}"
            datasourceUid   = "tempo-tob-${id}"
            urlDisplayLabel = "View trace"
          }]
        })
      }
      "tempo-tob-${id}" = {
        type       = "tempo"
        uid        = "tempo-tob-${id}"
        name       = "Tempo tob-${id}"
        url        = var.tempo_query_url
        org_id     = "tob-${id}"
        is_default = false
        json_data = jsonencode({
          httpMethod = "GET"
          tracesToLogsV2 = {
            datasourceUid   = "loki-tob-${id}"
            filterByTraceID = true
            filterBySpanID  = false
          }
          tracesToProfiles = {
            datasourceUid = "pyroscope-tob-${id}"
          }
          tracesToMetrics = {
            datasourceUid = "prometheus-tob-${id}"
          }
          serviceMap = {
            datasourceUid = "prometheus-tob-${id}"
          }
          nodeGraph = {
            enabled = true
          }
        })
      }
      "pyroscope-tob-${id}" = {
        type       = "grafana-pyroscope-datasource"
        uid        = "pyroscope-tob-${id}"
        name       = "Pyroscope tob-${id}"
        url        = local.pyroscope_http_url
        org_id     = "tob-${id}"
        is_default = false
        json_data  = jsonencode({})
      }
    }
  ]...)

  # uid prometheus is what the ToB dashboard's infrastructure panels query.
  # Tenant panels use prometheus-tob-<id> and loki-tob-<id> from the same JSON.
  tob_datasources = merge(local.tob_tenant_datasources, {
    prometheus = {
      type       = "prometheus"
      uid        = "prometheus"
      name       = "Prometheus"
      url        = local.prometheus_query_url
      org_id     = var.org_id
      is_default = true
      json_data = jsonencode({
        timeInterval = "15s"
        httpMethod   = "POST"
        exemplarTraceIdDestinations = [{
          name          = "trace_id"
          datasourceUid = "tempo-tob-${var.tenant}"
        }]
      })
    }
  })

  line_datasources = var.business_line == "toc" ? local.toc_datasources : local.tob_datasources
}

resource "grafana_folder" "line" {
  count = var.manage_grafana ? 1 : 0

  title = var.business_line == "toc" ? "ToC" : "ToB"
  uid   = "attach-${var.business_line}"

  lifecycle {
    precondition {
      condition     = var.grafana_auth != null && var.grafana_auth != ""
      error_message = "Set TF_VAR_grafana_auth to a token for the existing Grafana, or set manage_grafana=false."
    }
  }
}

resource "grafana_data_source" "signal" {
  for_each = var.manage_grafana ? local.line_datasources : {}

  type              = each.value.type
  uid               = each.value.uid
  name              = each.value.name
  url               = each.value.url
  is_default        = each.value.is_default
  json_data_encoded = each.value.json_data
  http_headers = {
    "X-Scope-OrgID" = each.value.org_id
    Authorization   = "Bearer ${local.ingest_token_value}"
  }

  lifecycle {
    precondition {
      condition     = var.grafana_auth != null && var.grafana_auth != ""
      error_message = "Set TF_VAR_grafana_auth to a token for the existing Grafana, or set manage_grafana=false."
    }
  }
}

resource "grafana_dashboard" "line" {
  count = var.manage_grafana ? 1 : 0

  # Existing ToC or ToB dashboard JSON. Not an empty dashboard.
  config_json = local.dashboard_json
  folder      = grafana_folder.line[0].uid
  overwrite   = true
  message     = "attach-existing ${var.business_line} ${var.org_id}"

  depends_on = [grafana_data_source.signal]
}
