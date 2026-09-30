variable "prometheus_remote_write_url" {
  type        = string
  description = "Remote-write URL of the Prometheus or Mimir that already exists. Example: http://prometheus.obs.example.invalid:9090/api/v1/write. This stack does not create Prometheus."

  validation {
    condition = (
      can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.prometheus_remote_write_url)) &&
      !strcontains(var.prometheus_remote_write_url, "observability.svc") &&
      !strcontains(var.prometheus_remote_write_url, "://prometheus:") &&
      !strcontains(var.prometheus_remote_write_url, "://prometheus/")
    )
    error_message = "prometheus_remote_write_url must be the existing system's URL. Do not use prometheus.observability.svc or http://prometheus:9090."
  }
}

variable "loki_push_url" {
  type        = string
  description = "Push URL of the Loki that already exists. Example: http://loki.obs.example.invalid:3100/loki/api/v1/push. This stack does not create Loki."

  validation {
    condition = (
      can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.loki_push_url)) &&
      !strcontains(var.loki_push_url, "observability.svc") &&
      !strcontains(var.loki_push_url, "://loki:") &&
      !strcontains(var.loki_push_url, "://loki/")
    )
    error_message = "loki_push_url must be the existing system's URL. Do not use loki.observability.svc or http://loki:3100."
  }
}

variable "loki_otlp_endpoint" {
  type        = string
  default     = null
  description = "Loki OTLP base URL. Null derives it as <origin of loki_push_url>/otlp. The collector appends /v1/logs."

  validation {
    condition = (
      (
        var.loki_otlp_endpoint == null ||
        can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.loki_otlp_endpoint))
      ) &&
      !strcontains(var.loki_otlp_endpoint == null ? "" : var.loki_otlp_endpoint, "observability.svc")
    )
    error_message = "loki_otlp_endpoint must be an http(s) URL on the existing Loki, or null."
  }
}

variable "loki_query_url" {
  type        = string
  default     = null
  description = "Loki base URL Grafana uses for queries. Null strips /loki/api/v1/push from loki_push_url."

  validation {
    condition = (
      (
        var.loki_query_url == null ||
        can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.loki_query_url))
      ) &&
      !strcontains(var.loki_query_url == null ? "" : var.loki_query_url, "observability.svc")
    )
    error_message = "loki_query_url must be an http(s) URL on the existing Loki, or null."
  }
}

variable "tempo_otlp_endpoint" {
  type        = string
  description = "Tempo OTLP gRPC host:port that already exists, without a scheme. Example: tempo.obs.example.invalid:4317. This stack does not create Tempo."

  validation {
    condition = (
      can(regex("^[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+:[0-9]+$", var.tempo_otlp_endpoint)) &&
      !strcontains(var.tempo_otlp_endpoint, "observability.svc") &&
      !startswith(var.tempo_otlp_endpoint, "tempo:")
    )
    error_message = "tempo_otlp_endpoint must be host:port on the existing Tempo. Do not use tempo.observability.svc or tempo:4317."
  }
}

variable "tempo_query_url" {
  type        = string
  description = "Tempo query URL Grafana uses, usually port 3200. Example: http://tempo.obs.example.invalid:3200. OTLP ingest is tempo_otlp_endpoint and is often a different port."

  validation {
    condition = (
      can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.tempo_query_url)) &&
      !strcontains(var.tempo_query_url, "observability.svc") &&
      !strcontains(var.tempo_query_url, "://tempo:") &&
      !strcontains(var.tempo_query_url, "://tempo/")
    )
    error_message = "tempo_query_url must be the existing Tempo HTTP query URL. Do not use tempo.observability.svc."
  }
}

variable "pyroscope_url" {
  type        = string
  description = "Base URL of the Pyroscope that already exists. Example: http://pyroscope.obs.example.invalid:4040. Used as the HTTP URL and, with the scheme removed, as the OTLP gRPC host:port. This stack does not create Pyroscope."

  validation {
    condition = (
      can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+:[0-9]+/?$", var.pyroscope_url)) &&
      !strcontains(var.pyroscope_url, "observability.svc") &&
      !strcontains(var.pyroscope_url, "://pyroscope:") &&
      !strcontains(var.pyroscope_url, "://pyroscope/")
    )
    error_message = "pyroscope_url must be the existing Pyroscope URL, including the port. Do not use pyroscope.observability.svc."
  }
}

variable "prometheus_query_url" {
  type        = string
  default     = null
  description = "Prometheus base URL Grafana queries. Null strips /api/v1/write or /api/v1/push from prometheus_remote_write_url. Set this when query and remote write are different hosts, such as a Mimir gateway."

  validation {
    condition = (
      (
        var.prometheus_query_url == null ||
        can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.prometheus_query_url))
      ) &&
      !strcontains(var.prometheus_query_url == null ? "" : var.prometheus_query_url, "observability.svc")
    )
    error_message = "prometheus_query_url must be an http(s) URL on the existing Prometheus, or null."
  }
}

variable "grafana_url" {
  type        = string
  description = "URL of the Grafana that already exists. Example: http://grafana.obs.example.invalid:3000. This stack does not create Grafana. It registers datasources, one dashboard, and alert rules through the Grafana API."

  validation {
    condition = (
      can(regex("^https?://[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+", var.grafana_url)) &&
      !strcontains(var.grafana_url, "observability.svc") &&
      !strcontains(var.grafana_url, "://grafana:") &&
      !strcontains(var.grafana_url, "://grafana/")
    )
    error_message = "grafana_url must be the existing Grafana. Do not use grafana.observability.svc."
  }
}

variable "grafana_auth" {
  type        = string
  default     = null
  sensitive   = true
  description = "Grafana API token (or user:password) for the existing Grafana. Sensitive. Pass it as TF_VAR_grafana_auth. Never commit it. Required when manage_grafana is true."
}

variable "org_id" {
  type        = string
  description = "X-Scope-OrgID for this cluster. ToC is toc. ToB is tob-<tenant>, for example tob-acme. This is the header value, not the tenant label."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$", var.org_id))
    error_message = "org_id must be a DNS label such as toc or tob-acme."
  }
}

variable "tenant" {
  type        = string
  description = "Low-cardinality tenant label sent with cluster and business_line. ToC is consumer. ToB is the tenant id from config/tenancy.yaml, such as acme or northwind. Not a user id."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.tenant))
    error_message = "tenant must be a DNS label from the tenancy catalog, not a user id."
  }
}

variable "business_line" {
  type        = string
  description = "Business line for this cluster. toc selects config/grafana/dashboards/toc-line.json. tob selects tob-line.json."

  validation {
    condition     = contains(["toc", "tob"], var.business_line)
    error_message = "business_line must be toc or tob."
  }
}

variable "cluster_name" {
  type        = string
  description = "cluster label written by the agent on this workload cluster. One value per cluster."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a DNS label."
  }
}

variable "kubeconfig" {
  type        = string
  description = "Kubeconfig path for the workload cluster only. This stack does not read a central-cluster kubeconfig. Do not commit the file."
}

variable "kube_context" {
  type        = string
  default     = ""
  description = "Context inside kubeconfig. Empty uses the file's current context."
}

variable "ingest_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Bearer token for the existing ingest endpoints and for Grafana datasource Authorization headers. Sensitive. Pass it as TF_VAR_ingest_token. Never put it in tfvars or git. The raw token only; the agent and the datasource header add the Bearer scheme."
}

variable "manage_grafana" {
  type        = bool
  default     = true
  description = "When true, register datasources, the business-line dashboard, and Grafana alert rules on the existing Grafana. Set false for a second cluster that should only install the agent; the first state already owns those Grafana objects."
}

variable "collector_replicas" {
  type        = number
  default     = 2
  description = "Replicas of the stateless workload collector. Alloy stays a DaemonSet. This does not scale Prometheus, Loki, Tempo, or Pyroscope."

  validation {
    condition     = var.collector_replicas >= 2 && var.collector_replicas <= 5
    error_message = "collector_replicas must be 2-5."
  }
}
