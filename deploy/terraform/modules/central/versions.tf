terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = "2.38.0"
      configuration_aliases = [kubernetes.this]
    }
  }
}
