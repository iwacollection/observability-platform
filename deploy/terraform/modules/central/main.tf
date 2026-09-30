locals {
  repo_root = abspath("${path.module}/../../../..")
  overlay   = "${local.repo_root}/deploy/kubernetes/overlays/${var.overlay}"
  # Declared inputs. The no-cluster coverage check compares kustomize output
  # to this file. Adding a manifest without listing it fails `make config-check`.
  managed_resources   = yamldecode(file("${path.module}/managed_resources.yaml"))
  required_components = toset(local.managed_resources.required_components)
  managed_ids = sort(flatten([
    for component, items in local.managed_resources.components : [
      for item in items : "${component}:${item.kind}/${item.name}"
    ]
  ]))
  ingest_auth_name = one([
    for item in local.managed_resources.components.secrets : item.name
    if item.kind == "Secret" && item.name == "ingest-auth"
  ])
  grafana_admin_secret_name = one([
    for item in local.managed_resources.components.secrets : item.name
    if item.kind == "Secret" && item.name == "grafana-admin"
  ])
  # Prod Secret ingest-auth is kubernetes_secret_v1. The apply script must not
  # also kubectl-apply it. Dev keeps the placeholder from the overlay.
  ingest_secret_mode = var.overlay == "prod" ? "provider" : "script"
  checksum = sha256(join("", concat(
    [filesha256("${local.repo_root}/deploy/terraform/scripts/kubectl-apply.sh")],
    [filesha256("${path.module}/managed_resources.yaml")],
    [for f in sort(fileset("${local.repo_root}/config", "**")) : filesha256("${local.repo_root}/config/${f}")],
    [for f in sort(fileset("${local.repo_root}/deploy/kubernetes", "**")) : filesha256("${local.repo_root}/deploy/kubernetes/${f}")],
  )))
}

# Destroy hook only. A checksum change must not run this provisioner: that
# would kubectl-delete the stack, including PVCs, on every config edit.
# `input` updates in place. The apply resource below is what gets replaced.
resource "terraform_data" "stack" {
  input = {
    kubeconfig   = var.kubeconfig
    kube_context = var.kube_context
    repo_root    = local.repo_root
    overlay      = local.overlay
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

resource "terraform_data" "stack_apply" {
  depends_on = [terraform_data.stack]

  triggers_replace = {
    checksum            = local.checksum
    overlay             = local.overlay
    kubeconfig          = var.kubeconfig
    kube_context        = var.kube_context
    generated_workloads = join(",", var.generated_workload_names)
    ingest_secret_mode  = local.ingest_secret_mode
    managed_ids         = join(",", local.managed_ids)
    alert_webhook_sha   = nonsensitive(sha256(coalesce(var.alert_webhook_url, "")))
  }

  input = {
    kubeconfig         = var.kubeconfig
    kube_context       = var.kube_context
    repo_root          = local.repo_root
    overlay            = local.overlay
    ingest_secret_mode = local.ingest_secret_mode
    # Prod token stays on kubernetes_secret_v1. Do not put it in this input.
    ingest_token      = local.ingest_secret_mode == "script" ? coalesce(var.ingest_token, "") : ""
    alert_webhook_url = coalesce(var.alert_webhook_url, "")
  }

  provisioner "local-exec" {
    command = "bash \"${self.input.repo_root}/deploy/terraform/scripts/kubectl-apply.sh\" apply"
    environment = {
      KUBECONFIG           = self.input.kubeconfig
      KUBE_CONTEXT         = self.input.kube_context
      KUSTOMIZE_PATH       = self.input.overlay
      INGEST_TOKEN         = self.input.ingest_token
      INGEST_SECRET_MODE   = self.input.ingest_secret_mode
      MANAGE_ALERT_WEBHOOK = "true"
      ALERT_WEBHOOK_URL    = self.input.alert_webhook_url
    }
  }

  lifecycle {
    precondition {
      condition     = length(setsubtract(local.required_components, toset(keys(local.managed_resources.components)))) == 0
      error_message = "managed_resources.yaml required_components must each have a components entry."
    }
    precondition {
      condition = alltrue([
        for name in [
          "toc-checkout",
          "tob-admin-acme",
          "tob-billing-acme",
          "tob-admin-northwind",
          "tob-billing-northwind",
        ] : contains(var.generated_workload_names, name)
      ])
      error_message = "generated_workload_names must include toc-checkout and the acme and northwind ToB workloads from config/tenancy.yaml."
    }
    precondition {
      condition     = var.overlay != "prod" || (var.ingest_token != null && var.ingest_token != "")
      error_message = "central overlay prod requires TF_VAR_ingest_token. Terraform creates Secret ingest-auth. Do not kubectl-apply the example Secret."
    }
  }
}

resource "kubernetes_secret_v1" "grafana_admin" {
  provider = kubernetes.this
  count    = var.grafana_admin_password == null ? 0 : 1

  depends_on = [terraform_data.stack_apply]

  metadata {
    name      = local.grafana_admin_secret_name
    namespace = "observability"
  }

  type = "Opaque"

  data = {
    admin-user = var.grafana_admin_user
    password   = var.grafana_admin_password
  }
}

# Prod only. The dev overlay already ships the local placeholder secret.
resource "kubernetes_secret_v1" "ingest_auth" {
  provider = kubernetes.this
  count    = var.overlay == "prod" ? 1 : 0

  depends_on = [terraform_data.stack_apply]

  metadata {
    name      = local.ingest_auth_name
    namespace = "observability"
    labels = {
      "app.kubernetes.io/name"       = "ingest-auth"
      "app.kubernetes.io/part-of"    = "observability-platform"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "Opaque"

  data = {
    token = coalesce(var.ingest_token, "missing")
  }

  lifecycle {
    precondition {
      condition     = var.ingest_token != null && var.ingest_token != ""
      error_message = "TF_VAR_ingest_token is required to create Secret ingest-auth on the prod overlay."
    }
  }
}
