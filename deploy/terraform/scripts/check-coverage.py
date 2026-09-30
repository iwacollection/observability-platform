#!/usr/bin/env python3
"""Fail if a platform kustomize object is missing from the Terraform inputs.

Does not read a kubeconfig and does not talk to an API server.
`make config-check` runs this after `terraform validate`.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
HASH_SUFFIX = re.compile(r"^[a-z0-9]{10}$")
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding"}

EXPECTED_CENTRAL = {
    "namespace",
    "prometheus",
    "alertmanager",
    "loki",
    "tempo",
    "pyroscope",
    "grafana",
    "dashboards",
    "rules",
    "ingest-gateway",
    "otel-collector",
    "alloy",
    "node-exporter",
    "kube-state-metrics",
    "middleware",
    "workloads",
    "endpoints",
    "tenancy",
    "networkpolicy",
    "secrets",
}
EXPECTED_AGENT = {
    "namespace",
    "otel-collector",
    "alloy",
    "node-exporter",
    "kube-state-metrics",
    "networkpolicy",
    "endpoints",
    "secrets",
}
EXPECTED_BINDING = {"cluster-binding"}
REQUIRED_WORKLOADS = {
    "toc-checkout",
    "tob-admin-acme",
    "tob-billing-acme",
    "tob-admin-northwind",
    "tob-billing-northwind",
}
REQUIRED_DASHBOARDS = {
    "overview.json",
    "logs.json",
    "traces.json",
    "profiles.json",
    "host.json",
    "demo-app.json",
    "infrastructure.json",
    "middleware.json",
    "application.json",
    "business.json",
    "meta.json",
    "toc-line.json",
    "tob-line.json",
}
REQUIRED_RULES = {"alerts.yml", "recording.yml", "tenancy.yml"}
INGEST_SIDECARS = ("prometheus", "loki", "tempo", "pyroscope")


def fail(errors: list[str]) -> None:
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)


def load_yaml(path: Path):
    return yaml.safe_load(path.read_text())


def generated_workload_names(tenancy: dict) -> list[str]:
    names: list[str] = []
    toc = tenancy["business_lines"]["toc"]
    for service in toc["services"]:
        # toc-api is Deployment demo-app, listed in the static inventory.
        if service.get("compose_service") == "demo-app":
            continue
        names.append(service["compose_service"])
    for tenant in tenancy["business_lines"]["tob"]["tenants"]:
        for service in tenancy["business_lines"]["tob"]["services"]:
            names.append(f"{service['name']}-{tenant['id']}")
    return names


def configmap_names(inventory: dict) -> set[str]:
    names = set()
    for items in inventory["components"].values():
        for item in items:
            if item["kind"] == "ConfigMap":
                names.add(item["name"])
    return names


def normalize(kind: str, name: str, configmaps: set[str]) -> str:
    if kind != "ConfigMap" or name in configmaps:
        return name
    matches = [candidate for candidate in configmaps if name.startswith(candidate + "-")]
    if not matches:
        return name
    best = max(matches, key=len)
    suffix = name[len(best) + 1 :]
    if HASH_SUFFIX.fullmatch(suffix):
        return best
    return name


def declared_ids(inventory: dict, overlay: str, generated: list[str]) -> set[tuple[str, str]]:
    ids: set[tuple[str, str]] = set()
    for items in inventory["components"].values():
        for item in items:
            if overlay in (item.get("kustomize") or []):
                ids.add((item["kind"], item["name"]))
    generated_spec = inventory.get("generated_workloads") or {}
    if overlay in (generated_spec.get("kustomize") or []):
        for kind in generated_spec.get("kinds") or []:
            for name in generated:
                ids.add((kind, name))
    return ids


def kustomize_build(path: Path) -> str:
    result = subprocess.run(
        ["kustomize", "build", "--load-restrictor", "LoadRestrictionsNone", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"kustomize build {path} failed:\n{result.stderr}")
    return result.stdout


def rendered_objects(text: str) -> list[dict]:
    objects = []
    for doc in yaml.safe_load_all(text):
        if not isinstance(doc, dict) or "kind" not in doc:
            continue
        meta = doc.get("metadata") or {}
        objects.append(
            {
                "kind": doc["kind"],
                "name": meta.get("name"),
                "namespace": meta.get("namespace"),
                "doc": doc,
            }
        )
    return objects


def missing_ids(rendered: set[tuple[str, str]], declared: set[tuple[str, str]]) -> list[str]:
    return sorted(f"{kind}/{name}" for kind, name in rendered - declared)


def self_test() -> None:
    declared = {("Deployment", "prometheus")}
    rendered = {("Deployment", "prometheus"), ("Deployment", "forgotten")}
    missing = missing_ids(rendered, declared)
    if missing != ["Deployment/forgotten"]:
        raise SystemExit(f"coverage self-test failed: {missing}")
    known = {"grafana-dashboards", "grafana-dashboards-provider"}
    if normalize("ConfigMap", "grafana-dashboards-provider-29897h22d7", known) != "grafana-dashboards-provider":
        raise SystemExit("coverage self-test failed: longest configmap prefix")
    if normalize("ConfigMap", "grafana-dashboards-k965kb75bd", known) != "grafana-dashboards":
        raise SystemExit("coverage self-test failed: dashboard configmap hash")
    if normalize("ConfigMap", "observability-endpoints", {"observability-endpoints"}) != "observability-endpoints":
        raise SystemExit("coverage self-test failed: unhashed configmap")
    print("coverage self-test ok")


def require_components(errors: list[str], label: str, inventory: dict, expected: set[str]) -> None:
    got = set(inventory.get("required_components") or [])
    keys = set(inventory.get("components") or {})
    if got != expected:
        errors.append(f"{label} required_components {sorted(got)} != {sorted(expected)}")
    if got != keys:
        errors.append(f"{label} component keys {sorted(keys)} != required_components")


def compare_overlay(
    errors: list[str],
    label: str,
    objects: list[dict],
    declared: set[tuple[str, str]],
    configmaps: set[str],
) -> dict[tuple[str, str], dict]:
    normalized: dict[tuple[str, str], dict] = {}
    rendered: set[tuple[str, str]] = set()
    for obj in objects:
        kind, name = obj["kind"], obj["name"]
        if not name:
            errors.append(f"{label} object {kind} has no name")
            continue
        logical = normalize(kind, name, configmaps)
        ident = (kind, logical)
        rendered.add(ident)
        normalized[ident] = obj
        if kind in CLUSTER_SCOPED:
            if obj["namespace"]:
                errors.append(f"{label} {kind}/{logical} must stay cluster-scoped")
        elif obj["namespace"] != "observability":
            errors.append(f"{label} {kind}/{name} namespace is {obj['namespace']!r}, want observability")
    for item in missing_ids(rendered, declared):
        errors.append(f"{label} rendered {item} is missing from the Terraform module inventory")
    for kind, name in sorted(declared - rendered):
        errors.append(f"{label} inventory {kind}/{name} is missing from kustomize build")
    return normalized


def configmap_keys(obj: dict) -> set[str]:
    return set((obj.get("doc") or {}).get("data") or {})


def container_names(obj: dict) -> list[str]:
    spec = ((obj.get("doc") or {}).get("spec") or {}).get("template", {}).get("spec", {})
    return [container.get("name") for container in spec.get("containers") or []]


def check_wiring(errors: list[str]) -> None:
    central_tf = (ROOT / "deploy/terraform/modules/central/main.tf").read_text()
    agent_tf = (ROOT / "deploy/terraform/modules/cluster_agent/main.tf").read_text()
    binding_tf = (ROOT / "deploy/terraform/modules/cluster_binding/main.tf").read_text()
    stack_tf = (ROOT / "deploy/terraform/stacks/platform/main.tf").read_text()
    tenancy_tf = (ROOT / "deploy/terraform/stacks/platform/tenancy.tf").read_text()
    variables_tf = (ROOT / "deploy/terraform/stacks/platform/variables.tf").read_text()
    script = (ROOT / "deploy/terraform/scripts/kubectl-apply.sh").read_text()

    if 'file("${path.module}/managed_resources.yaml")' not in central_tf:
        errors.append("central module does not read managed_resources.yaml")
    if 'file("${path.module}/managed_resources.yaml")' not in agent_tf:
        errors.append("cluster_agent module does not read managed_resources.yaml")
    if 'file("${path.module}/managed_resources.yaml")' not in binding_tf:
        errors.append("cluster_binding module does not read managed_resources.yaml")
    if "local.binding_name" not in binding_tf:
        errors.append("cluster binding ConfigMap name is not taken from managed_resources.yaml")
    if "local.ingest_auth_name" not in central_tf or 'resource "kubernetes_secret_v1" "ingest_auth"' not in central_tf:
        errors.append("prod Secret ingest-auth is not a kubernetes_secret_v1 input")
    if "local.grafana_admin_secret_name" not in central_tf:
        errors.append("grafana-admin Secret name is not taken from managed_resources.yaml")
    if "INGEST_SECRET_MODE" not in central_tf or "self.input.ingest_secret_mode" not in central_tf:
        errors.append("central apply does not pass INGEST_SECRET_MODE")
    if 'ingest_secret_mode = var.overlay == "prod" ? "provider" : "script"' not in central_tf:
        errors.append("prod overlay must set INGEST_SECRET_MODE=provider")
    if "INGEST_SECRET_MODE" not in script or "provider" not in script:
        errors.append("kubectl-apply.sh must skip Secret ingest-auth when mode is provider")
    if "observability-endpoints" not in script or "local.endpoints_configmap_name" not in agent_tf:
        errors.append("workload ConfigMap observability-endpoints is not created by terraform apply")
    if "local.ingest_secret_name" not in agent_tf:
        errors.append("workload Secret ingest-auth is not an input of the agent module")
    if "DELETE_INGEST_SECRET" not in agent_tf or "DELETE_INGEST_SECRET" not in script:
        errors.append("destroying a workload cluster must delete Secret ingest-auth")
    if "generated_workload_names" not in stack_tf or "generated_workload_names" not in tenancy_tf:
        errors.append("tenancy workload names are not a Terraform module input")
    if 'service.compose_service != "demo-app"' not in tenancy_tf:
        errors.append("tenancy.tf must skip demo-app when listing generated workload names")
    if "TF_VAR_ingest_token" not in variables_tf:
        errors.append("stack variables must require TF_VAR_ingest_token for the prod overlay")
    if 'resource "terraform_data" "stack_apply"' not in central_tf:
        errors.append("central apply resource terraform_data.stack_apply is missing")
    if 'resource "terraform_data" "agent_apply"' not in agent_tf:
        errors.append("agent apply resource terraform_data.agent_apply is missing")
    apply_at = central_tf.find('resource "terraform_data" "stack_apply"')
    destroy_at = central_tf.find("when    = destroy")
    if apply_at < 0 or destroy_at < 0 or destroy_at > apply_at:
        errors.append("central destroy provisioner must stay on terraform_data.stack, before stack_apply")
    if central_tf.find("when    = destroy", apply_at) != -1:
        errors.append("stack_apply must not kubectl-delete the stack when its checksum changes")
    agent_apply_at = agent_tf.find('resource "terraform_data" "agent_apply"')
    agent_destroy_at = agent_tf.find("when    = destroy")
    if agent_apply_at < 0 or agent_destroy_at < 0 or agent_destroy_at > agent_apply_at:
        errors.append("agent destroy provisioner must stay on terraform_data.agent, before agent_apply")
    if agent_tf.find("when    = destroy", agent_apply_at) != -1:
        errors.append("agent_apply must not kubectl-delete the cluster when its checksum changes")

    example = ROOT / "deploy/kubernetes/ingest-auth.secret.example.yaml"
    example_text = example.read_text()
    if "replace-me" not in example_text or "kind: Secret" not in example_text:
        errors.append("ingest-auth example must stay a shape document with token replace-me")
    if "dev-ingest-token" in example_text:
        errors.append("example secret must not contain the dev placeholder")
    for kust in (ROOT / "deploy/kubernetes").rglob("kustomization.yaml"):
        if "ingest-auth.secret.example.yaml" in kust.read_text():
            errors.append(f"{kust} references the example secret; Terraform owns prod ingest-auth")


def check_content(errors: list[str], label: str, objects_by_id: dict[tuple[str, str], dict]) -> None:
    dashboards = objects_by_id.get(("ConfigMap", "grafana-dashboards"))
    rules = objects_by_id.get(("ConfigMap", "prometheus-rules"))
    if dashboards is None or rules is None:
        return
    dashboard_dir = ROOT / "config/grafana/dashboards"
    on_disk = {path.name for path in dashboard_dir.glob("*.json")}
    rendered = configmap_keys(dashboards)
    if on_disk != rendered:
        errors.append(f"{label} grafana-dashboards keys {sorted(rendered)} != {sorted(on_disk)}")
    missing = REQUIRED_DASHBOARDS - rendered
    if missing:
        errors.append(f"{label} dashboards missing {sorted(missing)}")
    rule_dir = {path.name for path in (ROOT / "config/prometheus/rules").glob("*.yml")}
    rendered_rules = configmap_keys(rules)
    if rule_dir != rendered_rules:
        errors.append(f"{label} prometheus-rules keys {sorted(rendered_rules)} != {sorted(rule_dir)}")
    if not REQUIRED_RULES <= rendered_rules:
        errors.append(f"{label} rules missing {sorted(REQUIRED_RULES - rendered_rules)}")
    for name in INGEST_SIDECARS:
        deploy = objects_by_id.get(("Deployment", name))
        if deploy is None:
            errors.append(f"{label} missing Deployment {name} for the ingest gateway")
            continue
        if "ingest-gateway" not in container_names(deploy):
            errors.append(f"{label} Deployment {name} has no ingest-gateway container")


def main() -> None:
    self_test()
    errors: list[str] = []
    check_wiring(errors)

    central = load_yaml(ROOT / "deploy/terraform/modules/central/managed_resources.yaml")
    agent = load_yaml(ROOT / "deploy/terraform/modules/cluster_agent/managed_resources.yaml")
    binding = load_yaml(ROOT / "deploy/terraform/modules/cluster_binding/managed_resources.yaml")
    tenancy = load_yaml(ROOT / "config/tenancy.yaml")
    require_components(errors, "central", central, EXPECTED_CENTRAL)
    require_components(errors, "agent", agent, EXPECTED_AGENT)
    require_components(errors, "binding", binding, EXPECTED_BINDING)

    generated = generated_workload_names(tenancy)
    if not REQUIRED_WORKLOADS <= set(generated):
        errors.append(f"tenancy workloads missing {sorted(REQUIRED_WORKLOADS - set(generated))}")

    central_maps = configmap_names(central)
    agent_maps = configmap_names(agent)
    builds = {
        "dev": kustomize_build(ROOT / "deploy/kubernetes/overlays/dev"),
        "prod": kustomize_build(ROOT / "deploy/kubernetes/overlays/prod"),
        "agent": kustomize_build(ROOT / "deploy/kubernetes/agent"),
    }
    dev_objects = rendered_objects(builds["dev"])
    prod_objects = rendered_objects(builds["prod"])
    agent_objects = rendered_objects(builds["agent"])
    dev_by_id = compare_overlay(
        errors,
        "dev",
        dev_objects,
        declared_ids(central, "dev", generated),
        central_maps,
    )
    prod_by_id = compare_overlay(
        errors,
        "prod",
        prod_objects,
        declared_ids(central, "prod", generated),
        central_maps,
    )
    compare_overlay(
        errors,
        "agent",
        agent_objects,
        declared_ids(agent, "agent", []),
        agent_maps,
    )
    check_content(errors, "dev", dev_by_id)
    check_content(errors, "prod", prod_by_id)

    dev_secret = dev_by_id.get(("Secret", "ingest-auth"))
    if dev_secret is None:
        errors.append("dev overlay must render the placeholder Secret ingest-auth")
    elif "dev-ingest-token" not in builds["dev"]:
        errors.append("dev Secret ingest-auth lost the local placeholder")
    if ("Secret", "ingest-auth") in {(obj["kind"], normalize(obj["kind"], obj["name"], central_maps)) for obj in prod_objects}:
        errors.append("prod kustomize must not render Secret ingest-auth; Terraform creates it")
    if "dev-ingest-token" in builds["prod"]:
        errors.append("prod render contains the dev ingest placeholder")

    binding_name = binding["components"]["cluster-binding"][0]["name"]
    if binding_name != "observability-cluster-binding":
        errors.append("cluster binding ConfigMap was renamed without updating the contract")
    endpoint_names = [item["name"] for item in agent["components"]["endpoints"] if item["kind"] == "ConfigMap"]
    if endpoint_names != ["observability-endpoints"]:
        errors.append("agent inventory must name ConfigMap observability-endpoints")
    secret_names = [item["name"] for item in agent["components"]["secrets"] if item["kind"] == "Secret"]
    if secret_names != ["ingest-auth"]:
        errors.append("agent inventory must name Secret ingest-auth")

    fail(errors)
    print(
        "terraform coverage ok: "
        f"dev {len(dev_objects)} objects, prod {len(prod_objects)} objects, "
        f"agent {len(agent_objects)} objects"
    )


if __name__ == "__main__":
    main()
