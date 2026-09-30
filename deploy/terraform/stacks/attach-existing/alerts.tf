# Alert rules for the selected business line.
#
# The existing Prometheus is remote. This stack cannot ship
# config/prometheus/rules/tenancy.yml into it. The same PromQL is evaluated
# by Grafana unified alerting. Recording rules from that file are inlined
# below so the alerts do not depend on toc:payments:failure_ratio5m existing
# on the remote Prometheus.
#
# Names stay aligned with tenancy.yml: TocPaymentFailureRatio,
# TobInvoiceFailureRatio, TobSeatSaturation, TobApiQuotaHigh.

locals {
  toc_alerts = [
    {
      name    = "TocPaymentFailureRatio"
      pending = "5m"
      summary = "ToC payment failure ratio is above 10%"
      expr = trimspace(<<-EOT
        (
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_payments_total{business_line="toc",tenant="${local.toc_tenant}",result="failure"}[5m])
          )
          /
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_payments_total{business_line="toc",tenant="${local.toc_tenant}"}[5m])
          )
        ) > 0.1
        and
        sum by (cluster, tenant, business_line, service_name) (
          rate(business_payments_total{business_line="toc",tenant="${local.toc_tenant}"}[5m])
        ) > 0.05
      EOT
      )
    },
  ]

  tob_alerts = [
    {
      name    = "TobInvoiceFailureRatio"
      pending = "5m"
      summary = "ToB invoice failure ratio is above 10%"
      expr = trimspace(<<-EOT
        (
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_invoices_total{business_line="tob",tenant=~"${local.tob_tenant_re}",result="failure"}[5m])
          )
          /
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_invoices_total{business_line="tob",tenant=~"${local.tob_tenant_re}"}[5m])
          )
        ) > 0.1
        and
        sum by (cluster, tenant, business_line, service_name) (
          rate(business_invoices_total{business_line="tob",tenant=~"${local.tob_tenant_re}"}[5m])
        ) > 0.05
      EOT
      )
    },
    {
      name    = "TobSeatSaturation"
      pending = "10m"
      summary = "ToB seat utilization is above 90%"
      expr = trimspace(<<-EOT
        (
          sum by (cluster, tenant, business_line, service_name, plan) (
            business_seats_active{business_line="tob",tenant=~"${local.tob_tenant_re}"}
          )
          /
          clamp_min(
            sum by (cluster, tenant, business_line, service_name, plan) (
              business_seats_limit{business_line="tob",tenant=~"${local.tob_tenant_re}"}
            ),
            1
          )
        ) > 0.9
      EOT
      )
    },
    {
      name    = "TobApiQuotaHigh"
      pending = "10m"
      summary = "ToB API quota utilization is above 90%"
      expr = trimspace(<<-EOT
        (
          sum by (cluster, tenant, business_line, service_name, quota_class) (
            business_api_quota_used{business_line="tob",tenant=~"${local.tob_tenant_re}"}
          )
          /
          clamp_min(
            sum by (cluster, tenant, business_line, service_name, quota_class) (
              business_api_quota_limit{business_line="tob",tenant=~"${local.tob_tenant_re}"}
            ),
            1
          )
        ) > 0.9
      EOT
      )
    },
  ]

  line_alerts = var.business_line == "toc" ? local.toc_alerts : local.tob_alerts
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
