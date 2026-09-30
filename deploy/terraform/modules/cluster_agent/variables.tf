variable "cluster_name" {
  type        = string
  description = "Required cluster identity. Written to the cluster label. One value per cluster."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a DNS label (lowercase letters, digits, hyphens)."
  }
}

variable "kubeconfig" {
  type        = string
  description = "Kubeconfig path for this workload cluster. Not committed."
}

variable "kube_context" {
  type        = string
  default     = ""
  description = "kubeconfig context. Empty uses the file's current context."
}

variable "prometheus_remote_write_url" {
  type        = string
  description = "Central Prometheus remote-write URL, for example http://prometheus.central.example.invalid:9090/api/v1/write."
}

variable "loki_push_url" {
  type        = string
  description = "Central Loki push URL."
}

variable "loki_otlp_endpoint" {
  type        = string
  description = "Central Loki OTLP base URL (the collector appends /v1/logs)."
}

variable "tempo_otlp_endpoint" {
  type        = string
  description = "Central Tempo OTLP gRPC host:port."
}

variable "pyroscope_otlp_endpoint" {
  type        = string
  description = "Central Pyroscope OTLP gRPC host:port."
}

variable "pyroscope_http_url" {
  type        = string
  description = "Central Pyroscope HTTP URL for SDKs that push profiles directly."
}

variable "collector_replicas" {
  type        = number
  default     = 2
  description = "Replicas of the stateless workload collector. Both pods mount the same ConfigMap. Do not use this for Prometheus, Loki, Tempo, or Pyroscope."

  validation {
    condition     = var.collector_replicas >= 2 && var.collector_replicas <= 5
    error_message = "collector_replicas must be 2-5. Alloy stays a DaemonSet; storage binaries stay at one replica."
  }
}

variable "ingest_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Bearer token written to Secret ingest-auth on this workload cluster. Null skips the Secret. Required when require_ingest_token is true. Never commit the value."
}

variable "require_ingest_token" {
  type        = bool
  default     = false
  description = "When true, apply fails unless ingest_token is set. The platform stack sets this for central_overlay=prod. The attach-existing stack always sets it."
}

variable "tenant" {
  type        = string
  default     = ""
  description = "Tenant label stamped on this cluster's telemetry. Empty does not overwrite application labels. Not a user id."

  validation {
    condition     = var.tenant == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", var.tenant))
    error_message = "tenant must be empty or a DNS label."
  }
}

variable "business_line" {
  type        = string
  default     = ""
  description = "Business line stamped on this cluster's telemetry. Empty does not overwrite application labels."

  validation {
    condition     = contains(["", "toc", "tob"], var.business_line)
    error_message = "business_line must be empty, toc, or tob."
  }
}

variable "org_id" {
  type        = string
  default     = ""
  description = "X-Scope-OrgID for this cluster when attaching to an existing Loki, Tempo, or Pyroscope. Empty keeps pod labels and the collector's tenancy routing."

  validation {
    condition     = var.org_id == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$", var.org_id))
    error_message = "org_id must be empty or a DNS label such as toc or tob-acme."
  }
}

variable "exporter_tls_insecure" {
  type        = bool
  default     = false
  description = "Plaintext for the collector's Loki, Tempo, and Pyroscope OTLP exporters. False uses TLS (system roots, or exporter_tls_ca_pem). True is only for an explicit plaintext endpoint. The platform stack sets true because its central binaries are plaintext. attach-existing defaults to false."
}

variable "exporter_tls_ca_pem" {
  type        = string
  default     = null
  sensitive   = true
  description = "Optional PEM CA for the OTLP exporters. Written to Secret otel-exporter-tls-ca. Never commit the PEM. Ignored when exporter_tls_insecure is true."
}

variable "install_demo_workloads" {
  type        = bool
  default     = false
  description = "When true, install the generated ToC and ToB demo workloads from deploy/kubernetes/base. Default false. The platform stack leaves this false; workloads there come from the central overlay."
}
