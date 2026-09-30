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
  description = "Bearer token for remote write, Loki, Tempo, and Pyroscope ingest. Null skips Secret creation. The dev overlay already has the placeholder dev-ingest-token. Never commit this."
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
  }))
  description = "Workload clusters. Adding a cluster is a new map entry. The example aliases require the keys prod-a and prod-b."

  validation {
    condition = alltrue([
      contains(keys(var.workload_clusters), "prod-a"),
      contains(keys(var.workload_clusters), "prod-b"),
    ])
    error_message = "workload_clusters must include prod-a and prod-b because providers.tf binds those aliases. Set enabled=false to destroy one of them. A third cluster is another map entry plus a new alias."
  }

  validation {
    condition = alltrue([
      for k, v in var.workload_clusters : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", k))
    ])
    error_message = "Map keys are the cluster label. Use a DNS label, not a pod uid or user id."
  }
}
