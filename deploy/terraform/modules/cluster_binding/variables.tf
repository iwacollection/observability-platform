variable "cluster_name" {
  type        = string
  description = "Cluster label recorded by the Kubernetes provider on this cluster."
}

variable "enabled" {
  type        = bool
  default     = true
  description = "When false, Terraform deletes only this cluster's binding ConfigMap."
}
