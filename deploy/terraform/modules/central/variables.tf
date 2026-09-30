variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig for the central cluster. Not committed."
}

variable "kube_context" {
  type        = string
  default     = ""
  description = "kubeconfig context. Empty uses the file's current context."
}

variable "overlay" {
  type        = string
  default     = "dev"
  description = "Kustomize overlay under deploy/kubernetes/overlays. dev or prod."

  validation {
    condition     = contains(["dev", "prod"], var.overlay)
    error_message = "overlay must be dev or prod."
  }
}

variable "cluster_name" {
  type        = string
  default     = "local"
  description = "Identity label for the central stack. Must stay local unless prometheus.yml metric_relabel replacement is edited to the same value."

  validation {
    condition     = var.cluster_name == "local"
    error_message = "Central Prometheus stores cluster=local via metric_relabel in config/prometheus/prometheus.yml. Change that replacement, the endpoints ConfigMap, and this variable together."
  }
}

variable "grafana_admin_user" {
  type        = string
  default     = "admin"
  description = "Grafana admin user stored in the grafana-admin Secret when a password is set."
}

variable "grafana_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "When set, Terraform creates the grafana-admin Secret. Leave null and the Grafana pod waits until you set TF_VAR_grafana_admin_password and apply again. Never commit the value."
}

variable "ingest_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Bearer token for Secret ingest-auth. Required when overlay is prod: the Kubernetes provider creates the Secret. On dev, a non-empty value overrides the overlay placeholder. Never commit the value."
}

variable "generated_workload_names" {
  type        = list(string)
  description = "Deployment and Service names rendered from config/tenancy.yaml, excluding demo-app. Passed by stacks/platform."
}
