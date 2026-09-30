variable "central_kubeconfig" {
  type        = string
  description = "Kubeconfig path for the central observability cluster. Do not commit the file."
}

variable "central_kube_context" {
  type        = string
  default     = ""
  description = "Context inside central_kubeconfig. Empty uses the file default."
}

variable "central_overlay" {
  type        = string
  default     = "dev"
  description = "deploy/kubernetes/overlays name for the central stack."

  validation {
    condition     = contains(["dev", "prod"], var.central_overlay)
    error_message = "central_overlay must be dev or prod."
  }

  validation {
    condition     = var.central_overlay != "prod" || (var.ingest_token != null && var.ingest_token != "")
    error_message = "central_overlay=prod requires TF_VAR_ingest_token. Terraform creates Secret ingest-auth from that variable. Do not kubectl-apply the example Secret, and do not commit the token."
  }
}

variable "central_cluster_name" {
  type        = string
  default     = "local"
  description = "cluster label for the central stack. Pinned to local by the shared Prometheus config."
}

variable "grafana_admin_user" {
  type        = string
  default     = "admin"
  description = "Grafana admin user name when Terraform creates the Secret."
}

variable "grafana_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Grafana admin password. Null skips Secret creation. Never commit this."
}

variable "ingest_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Bearer token for Secret ingest-auth. Sensitive. Pass it as TF_VAR_ingest_token, never in tfvars or git. Required when central_overlay is prod. The dev overlay already contains the local placeholder dev-ingest-token."
}

variable "alert_webhook_url" {
  type        = string
  default     = null
  sensitive   = true
  description = "Optional paging webhook. Pass it as TF_VAR_alert_webhook_url. When unset, Alertmanager and Grafana keep critical and warning in the UI. When set, both route those severities to the URL, grouped by cluster, business_line, tenant, and alertname. Never commit the value."

  validation {
    condition     = var.alert_webhook_url == null || var.alert_webhook_url == "" || can(regex("^https?://[^\\s\"']+$", var.alert_webhook_url))
    error_message = "alert_webhook_url must be an http or https URL without spaces or quotes, or unset."
  }
}

variable "workload_collector_replicas" {
  type        = number
  default     = 2
  description = "Replicas of the stateless workload otel-collector. Alloy remains a DaemonSet. Central Prometheus, Loki, Tempo, and Pyroscope stay at one replica on local disks."

  validation {
    condition     = var.workload_collector_replicas >= 2 && var.workload_collector_replicas <= 5
    error_message = "workload_collector_replicas must be 2-5."
  }
}

variable "workload_clusters" {
  type = map(object({
    enabled                     = optional(bool, true)
    kubeconfig                  = string
    context                     = optional(string)
    prometheus_remote_write_url = string
    loki_push_url               = string
    loki_otlp_endpoint          = string
    tempo_otlp_endpoint         = string
    pyroscope_otlp_endpoint     = string
    pyroscope_http_url          = string
    # True because this repo's central Loki, Tempo, and Pyroscope are plaintext.
    # Set false only when those three OTLP endpoints actually speak TLS.
    exporter_tls_insecure = optional(bool, true)
  }))
  description = "Workload clusters. Adding a cluster is one map entry. The agent and ConfigMap observability-cluster-binding are applied with that entry's kubeconfig. There is no per-cluster provider alias."

  validation {
    condition = alltrue([
      for k, v in var.workload_clusters : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", k))
    ])
    error_message = "Map keys are the cluster label. Use a DNS label, not a pod uid or user id."
  }
}
