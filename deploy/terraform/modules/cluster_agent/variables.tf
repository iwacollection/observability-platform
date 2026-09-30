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
  description = "Bearer token for the central ingest gateway. Null skips Secret creation. Never commit the value."
}
