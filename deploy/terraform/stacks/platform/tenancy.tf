# The catalog is config/tenancy.yaml. Adding a business line or a ToB tenant
# is an edit to that map, then `make render-tenancy`, then `terraform apply`.
# Apply ships the rendered collector config, Grafana datasources, rules, and
# workloads through the existing kustomize path. This file only validates the
# map and publishes it as an output.
#
# for_each still cannot take a different kubernetes provider alias per
# instance. Tenants are not clusters, so they do not need a provider alias.
# A third cluster is still a map entry plus a new alias in providers.tf.

locals {
  tenancy_file = "${path.module}/../../../../config/tenancy.yaml"
  tenancy      = yamldecode(file(local.tenancy_file))
  tob_tenants  = local.tenancy.business_lines.tob.tenants
  tob_tenant_ids = [
    for tenant in local.tob_tenants : tenant.id
  ]
  tenancy_org_ids = concat(
    [
      local.tenancy.business_lines.toc.org_id,
      local.tenancy.platform_org_id,
      local.tenancy.rejected_org_id,
    ],
    [for tenant in local.tob_tenants : tenant.org_id],
  )
  # toc-api is Deployment/Service demo-app, already in the central inventory.
  # Every other rendered workload name is an input to module.central.
  toc_workload_names = [
    for service in local.tenancy.business_lines.toc.services : service.compose_service
    if service.compose_service != "demo-app"
  ]
  tob_workload_names = flatten([
    for tenant in local.tob_tenants : [
      for service in local.tenancy.business_lines.tob.services : "${service.name}-${tenant.id}"
    ]
  ])
  generated_workload_names = concat(local.toc_workload_names, local.tob_workload_names)
}

resource "terraform_data" "tenancy_catalog" {
  input = {
    toc_tenant     = local.tenancy.business_lines.toc.tenant
    toc_services   = [for service in local.tenancy.business_lines.toc.services : service.name]
    tob_tenants    = local.tob_tenant_ids
    tob_services   = [for service in local.tenancy.business_lines.tob.services : service.name]
    org_ids        = local.tenancy_org_ids
    toc_clusters   = local.tenancy.business_lines.toc.clusters
    tob_clusters   = local.tenancy.business_lines.tob.clusters
    tenancy_sha256 = filesha256(local.tenancy_file)
  }

  lifecycle {
    precondition {
      condition = (
        local.tenancy.business_lines.toc.kind == "toc" &&
        local.tenancy.business_lines.tob.kind == "tob" &&
        local.tenancy.business_lines.toc.org_id == "toc" &&
        length(local.tenancy.business_lines.toc.services) >= 2 &&
        length(local.tenancy.business_lines.tob.services) >= 2 &&
        length(local.tob_tenant_ids) >= 2 &&
        alltrue([
          for id in local.tob_tenant_ids : can(regex("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", id))
        ]) &&
        alltrue([
          for tenant in local.tob_tenants : tenant.org_id == "tob-${tenant.id}"
        ])
      )
      error_message = "config/tenancy.yaml must describe a ToC line and a ToB line. ToB org ids are tob-<tenant>. Tenant ids are DNS labels, not user ids or order ids."
    }
  }
}
