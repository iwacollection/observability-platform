# Alert rules for the selected business line.
#
# Expressions come from generated/grafana-line-alerts.json, which
# scripts/render_tenancy.py builds by inlining config/prometheus/rules/tenancy.yml.
# Recording-rule names such as toc:payments:failure_ratio5m are not created
# on the remote Prometheus. This stack does not upload the rule file: that
# would need a live Prometheus, and Prometheus has no rules API. The YAML is
# output as prometheus_tenancy_rules for the case where the existing system
# is this repo's Prometheus (the platform stack already mounts that file).

locals {
  grafana_line_alerts = jsondecode(file("${path.module}/generated/grafana-line-alerts.json"))
  line_alerts         = local.grafana_line_alerts.alerts[var.business_line]
}

resource "grafana_rule_group" "line" {
  count = var.manage_grafana ? 1 : 0

  name             = "${var.business_line}-tenancy"
  folder_uid       = grafana_folder.line[0].uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.line_alerts
    content {
      name           = rule.value.name
      for            = rule.value.pending
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Error"

      labels = {
        severity      = "warning"
        layer         = "business"
        business_line = var.business_line
        source        = "grafana"
      }

      annotations = {
        summary = rule.value.summary
      }

      data {
        ref_id         = "A"
        datasource_uid = local.alert_datasource_uid
        model = jsonencode({
          editorMode    = "code"
          expr          = rule.value.expr
          instant       = true
          intervalMs    = 1000
          legendFormat  = "__auto"
          maxDataPoints = 43200
          range         = false
          refId         = "A"
        })
        relative_time_range {
          from = 600
          to   = 0
        }
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"
        model = jsonencode({
          expression = "A"
          reducer    = "last"
          refId      = "B"
          type       = "reduce"
        })
        relative_time_range {
          from = 600
          to   = 0
        }
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        model = jsonencode({
          conditions = [{
            evaluator = {
              params = [0]
              type   = "gt"
            }
            operator = {
              type = "and"
            }
            query = {
              params = ["B"]
            }
            reducer = {
              params = []
              type   = "last"
            }
            type = "query"
          }]
          datasource = {
            type = "__expr__"
            uid  = "__expr__"
          }
          expression = "B"
          refId      = "C"
          type       = "threshold"
        })
        relative_time_range {
          from = 600
          to   = 0
        }
      }
    }
  }

  depends_on = [grafana_data_source.signal]
}
