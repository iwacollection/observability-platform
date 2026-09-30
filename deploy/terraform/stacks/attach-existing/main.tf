# Attach one workload cluster to an observability system that already exists.
# Applying this stack installs the agent (Alloy, Collector, node-exporter,
# kube-state-metrics) and, when manage_grafana is true, registers datasources,
# one existing dashboard, and Grafana alert rules.
#
# It does not create Prometheus, Loki, Tempo, Pyroscope, or Grafana.
# Do not point the URLs at this repo's in-cluster DNS
# (prometheus.observability.svc and the other observability.svc names).

locals {
  tenancy_file = "${path.module}/../../../../config/tenancy.yaml"
  tenancy      = yamldecode(file(local.tenancy_file))
  toc_tenant   = local.tenancy.business_lines.toc.tenant
  toc_org_id   = local.tenancy.business_lines.toc.org_id
  tob_tenant_ids = [
    for tenant in local.tenancy.business_lines.tob.tenants : tenant.id
  ]
  tob_tenant_re = join("|", local.tob_tenant_ids)

  toc_dashboard_path = "${path.module}/../../../../config/grafana/dashboards/toc-line.json"
  tob_dashboard_path = "${path.module}/../../../../config/grafana/dashboards/tob-line.json"
  dashboard_json_path = (
    var.business_line == "toc" ? local.toc_dashboard_path : local.tob_dashboard_path
  )
  dashboard_json = (
    var.business_line == "toc" ? file(local.toc_dashboard_path) : file(local.tob_dashboard_path)
  )
  dashboard_uid = var.business_line == "toc" ? "toc-line" : "tob-line"

  rules_file = "${path.module}/../../../../config/prometheus/rules/tenancy.yml"

  ingest_token_value = var.ingest_token == null ? "" : var.ingest_token
  grafana_auth_value = var.grafana_auth == null ? "anonymous" : var.grafana_auth

  loki_origin = try(regex("^https?://[^/]+", var.loki_push_url), "")
  loki_query_url = (
    var.loki_query_url != null && var.loki_query_url != ""
    ? var.loki_query_url
    : trimsuffix(var.loki_push_url, "/loki/api/v1/push")
  )
  loki_otlp_endpoint = (
    var.loki_otlp_endpoint != null && var.loki_otlp_endpoint != ""
    ? var.loki_otlp_endpoint
    : "${local.loki_origin}/otlp"
  )
  prometheus_query_url = (
    var.prometheus_query_url != null && var.prometheus_query_url != ""
    ? var.prometheus_query_url
    : trimsuffix(trimsuffix(var.prometheus_remote_write_url, "/api/v1/write"), "/api/v1/push")
  )
  pyroscope_http_url      = trimsuffix(var.pyroscope_url, "/")
  pyroscope_otlp_endpoint = try(regex("^https?://([^/]+)$", local.pyroscope_http_url)[0], "")

  identity_ok = (
    var.business_line == "toc" &&
    var.tenant == local.toc_tenant &&
    var.org_id == local.toc_org_id
    ) || (
    var.business_line == "tob" &&
    contains(local.tob_tenant_ids, var.tenant) &&
    var.org_id == "tob-${var.tenant}"
  )
}

resource "terraform_data" "attach_contract" {
  input = {
    cluster_name      = var.cluster_name
    business_line     = var.business_line
    tenant            = var.tenant
    org_id            = var.org_id
    dashboard         = local.dashboard_json_path
    dashboard_uid     = local.dashboard_uid
    toc_dashboard_sha = filesha256(local.toc_dashboard_path)
    tob_dashboard_sha = filesha256(local.tob_dashboard_path)
    rules_sha         = filesha256(local.rules_file)
    creates_backends  = false
    prometheus        = var.prometheus_remote_write_url
    loki_push         = var.loki_push_url
    tempo             = var.tempo_otlp_endpoint
    pyroscope         = var.pyroscope_url
    agent_module      = "modules/cluster_agent"
  }

  lifecycle {
    precondition {
      condition     = local.identity_ok
      error_message = "business_line, tenant, and org_id must match config/tenancy.yaml. ToC is business_line=toc, tenant=consumer, org_id=toc. ToB is business_line=tob, tenant=<id>, org_id=tob-<id>."
    }
    precondition {
      condition     = var.ingest_token != null && var.ingest_token != ""
      error_message = "Set TF_VAR_ingest_token to the existing system's bearer token. Do not put it in tfvars."
    }
    precondition {
      condition = (
        (var.prometheus_query_url != null && var.prometheus_query_url != "") ||
        endswith(var.prometheus_remote_write_url, "/api/v1/write") ||
        endswith(var.prometheus_remote_write_url, "/api/v1/push")
      )
      error_message = "prometheus_remote_write_url must end in /api/v1/write or /api/v1/push, or set prometheus_query_url to the existing Prometheus query URL."
    }
    precondition {
      condition     = (var.loki_query_url != null && var.loki_query_url != "") || endswith(var.loki_push_url, "/loki/api/v1/push")
      error_message = "loki_push_url must end in /loki/api/v1/push, or set loki_query_url."
    }
    precondition {
      condition     = local.pyroscope_otlp_endpoint != "" && !strcontains(local.pyroscope_otlp_endpoint, "observability.svc")
      error_message = "pyroscope_url must be an http(s) URL with a host and port and no path, so the OTLP host:port can be derived."
    }
    precondition {
      condition = !strcontains(join(" ", [
        var.prometheus_remote_write_url,
        var.loki_push_url,
        local.loki_otlp_endpoint,
        var.tempo_otlp_endpoint,
        var.pyroscope_url,
        var.grafana_url,
        local.prometheus_query_url,
        local.loki_query_url,
        var.tempo_query_url,
      ]), "observability.svc")
      error_message = "Attach URLs must not use this repo's in-cluster DNS (prometheus.observability.svc and the other observability.svc names)."
    }
  }
}

module "agent" {
  source = "../../modules/cluster_agent"

  cluster_name                = var.cluster_name
  kubeconfig                  = var.kubeconfig
  kube_context                = var.kube_context
  prometheus_remote_write_url = var.prometheus_remote_write_url
  loki_push_url               = var.loki_push_url
  loki_otlp_endpoint          = local.loki_otlp_endpoint
  tempo_otlp_endpoint         = var.tempo_otlp_endpoint
  pyroscope_otlp_endpoint     = local.pyroscope_otlp_endpoint
  pyroscope_http_url          = local.pyroscope_http_url
  collector_replicas          = var.collector_replicas
  ingest_token                = var.ingest_token
  require_ingest_token        = true
  tenant                      = var.tenant
  business_line               = var.business_line
  org_id                      = var.org_id

  depends_on = [terraform_data.attach_contract]
}
