locals {
  repo_root = abspath("${path.module}/../../../..")
  overlay   = "${local.repo_root}/deploy/kubernetes/overlays/${var.overlay}"
  checksum = sha256(join("", concat(
    [filesha256("${local.repo_root}/deploy/terraform/scripts/kubectl-apply.sh")],
    [for f in sort(fileset("${local.repo_root}/config", "**")) : filesha256("${local.repo_root}/config/${f}")],
    [for f in sort(fileset("${local.repo_root}/deploy/kubernetes", "**")) : filesha256("${local.repo_root}/deploy/kubernetes/${f}")],
  )))
}

resource "terraform_data" "stack" {
  input = {
    kubeconfig   = var.kubeconfig
    kube_context = var.kube_context
    repo_root    = local.repo_root
    overlay      = local.overlay
    checksum     = local.checksum
    ingest_token = var.ingest_token
  }

  provisioner "local-exec" {
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" apply"
    environment = {
      KUBECONFIG     = self.input.kubeconfig
      KUBE_CONTEXT   = self.input.kube_context
      KUSTOMIZE_PATH = self.input.overlay
      INGEST_TOKEN   = self.input.ingest_token == null ? "" : self.input.ingest_token
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" delete"
    environment = {
      KUBECONFIG     = self.input.kubeconfig
      KUBE_CONTEXT   = self.input.kube_context
      KUSTOMIZE_PATH = self.input.overlay
    }
  }
}

resource "kubernetes_secret_v1" "grafana_admin" {
  provider = kubernetes.this
  count    = var.grafana_admin_password == null ? 0 : 1

  depends_on = [terraform_data.stack]

  metadata {
    name      = "grafana-admin"
    namespace = "observability"
  }

  type = "Opaque"

  data = {
    admin-user = var.grafana_admin_user
    password   = var.grafana_admin_password
  }
}
