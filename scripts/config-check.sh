#!/usr/bin/env bash
# Static checks for the observability configs. promtool, amtool, alloy,
# otelcol-contrib, loki, kustomize, and terraform are required. A missing
# binary is a failure. Docker Compose render is a separate optional step:
# skipping it does not validate the compose files.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail=0
note() { printf '== %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; fail=1; }

export PATH="/tmp/obs-tools/bin:${PATH}"

note "tenancy render"
python3 "$root/scripts/render_tenancy.py" --check || die "tenancy render drift"

note "local tenancy and exemplars"
python3 - <<'PY'
import json
import pathlib
import re
import sys

import yaml

root = pathlib.Path(".")
errors = []
compose = (root / "deploy/docker-compose/businesses.yml").read_text()
for needle in (
    "tob-admin-northwind:",
    "tob-billing-northwind:",
    "127.0.0.1:8084:8080",
    "127.0.0.1:8085:8080",
    "TENANT_ID: northwind",
):
    if needle not in compose:
        errors.append(f"local compose missing {needle}")

base = (root / "deploy/kubernetes/base/business-workloads.yaml").read_text()
# Prod inherits the base count. Northwind runs on base, dev, and prod.
if "name: tob-admin-northwind" not in base or "name: tob-billing-northwind" not in base:
    errors.append("base workloads missing northwind")
base_docs = list(yaml.safe_load_all(base))
for name in ("tob-admin-northwind", "tob-billing-northwind"):
    found = [
        doc for doc in base_docs
        if isinstance(doc, dict) and doc.get("kind") == "Deployment" and (doc.get("metadata") or {}).get("name") == name
    ]
    if len(found) != 1 or found[0]["spec"]["replicas"] != 1:
        errors.append(f"base {name} replicas are not 1")

prod = "\n".join(path.read_text() for path in (root / "deploy/kubernetes/overlays/prod").glob("*.yaml"))
if "dev-ingest-token" in prod:
    errors.append("prod overlay contains the dev ingest placeholder")

datasources = list(yaml.safe_load_all((root / "config/grafana/provisioning/datasources/tenancy.yaml").read_text()))
items = []
for doc in datasources:
    if isinstance(doc, dict):
        items.extend(doc.get("datasources") or [])
by_uid = {item.get("uid"): item for item in items}
main = yaml.safe_load((root / "config/grafana/provisioning/datasources/datasources.yaml").read_text())
for item in main.get("datasources") or []:
    by_uid[item.get("uid")] = item

def exemplar_uid(item):
    dests = (item.get("jsonData") or {}).get("exemplarTraceIdDestinations") or []
    if not dests:
        return None
    return dests[0].get("datasourceUid")

expected = {
    "prometheus": "tempo",
    "prometheus-tob-acme": "tempo-tob-acme",
    "prometheus-tob-northwind": "tempo-tob-northwind",
}
for uid, want in expected.items():
    got = exemplar_uid(by_uid.get(uid) or {})
    if got != want:
        errors.append(f"{uid} exemplar destination is {got}, want {want}")
    if uid.startswith("prometheus-tob-") and got == "tempo":
        errors.append(f"{uid} points at the ToC tempo uid")

tob = json.loads((root / "config/grafana/dashboards/tob-line.json").read_text())
seen = set()
for panel in tob.get("panels", []):
    ds = (panel.get("datasource") or {}).get("uid")
    for target in panel.get("targets") or []:
        if not target.get("exemplar"):
            continue
        target_uid = (target.get("datasource") or {}).get("uid")
        seen.add(target_uid)
        if target_uid in {None, "prometheus", "tempo"}:
            errors.append(f"tob exemplar panel {panel.get('id')} uses {target_uid}")
        mapped = exemplar_uid(by_uid.get(target_uid) or {})
        if mapped == "tempo":
            errors.append(f"tob exemplar panel {panel.get('id')} maps to ToC tempo")
for uid in ("prometheus-tob-acme", "prometheus-tob-northwind"):
    if uid not in seen:
        errors.append(f"tob-line.json has no exemplar panel on {uid}")

pyroscope = (root / "config/pyroscope/config.yaml").read_text()
if "multitenancy_enabled: true" not in pyroscope:
    errors.append("pyroscope multitenancy_enabled is not true")
collector = (root / "config/otel-collector/config.yaml").read_text()
for org in ("toc", "tob-acme", "tob-northwind"):
    if f"X-Scope-OrgID: {org}" not in collector:
        errors.append(f"collector missing X-Scope-OrgID {org}")
if "X-Scope-OrgID: rejected" not in collector:
    errors.append("collector OTLP profiles are not quarantined to org rejected")
if "otlp/pyroscope_acme:" in collector:
    errors.append("collector claims a per-tenant pyroscope route the 0.161 routing connector cannot do")
telemetry = (root / "examples/demo-app/src/demo_app/telemetry.py").read_text()
if "def pyroscope_push_settings" not in telemetry or 'os.environ.get("PYROSCOPE_HTTP_URL"' not in telemetry:
    errors.append("demo SDK does not use PYROSCOPE_HTTP_URL as the per-tenant profile path")
if 'tenant_id=settings["tenant_id"]' not in telemetry:
    errors.append("demo SDK does not send tenant_id from pyroscope_push_settings")
if re.search(r"(?m)^\s*insecure:\s+true\s*$", collector):
    errors.append("collector hardcodes tls insecure true")
if "${env:OTEL_EXPORTER_TLS_INSECURE:-false}" not in collector:
    errors.append("collector TLS insecure flag is not the env default false")
compose_main = (root / "deploy/docker-compose/docker-compose.yml").read_text()
if 'OTEL_EXPORTER_TLS_INSECURE: "true"' not in compose_main:
    errors.append("local compose does not set the explicit plaintext TLS flag")
endpoints = (root / "deploy/kubernetes/base/endpoints.yaml").read_text()
if 'OTEL_EXPORTER_TLS_INSECURE: "true"' not in endpoints:
    errors.append("central endpoints ConfigMap missing explicit plaintext TLS flag")
attach_vars = (root / "deploy/terraform/stacks/attach-existing/variables.tf").read_text()
if 'variable "exporter_tls_insecure"' not in attach_vars or "default     = false" not in attach_vars.split('variable "exporter_tls_insecure"', 1)[1].split('variable "', 1)[0]:
    errors.append("attach-existing exporter_tls_insecure does not default to false")
if 'variable "install_demo_workloads"' not in attach_vars or "default     = false" not in attach_vars.split('variable "install_demo_workloads"', 1)[1].split('variable "', 1)[0]:
    errors.append("attach-existing install_demo_workloads does not default to false")
alerts = json.loads((root / "deploy/terraform/stacks/attach-existing/generated/grafana-line-alerts.json").read_text())
if alerts.get("recording_rules_created_remotely") is not False:
    errors.append("attach grafana alerts claim recording rules are created remotely")
rules = yaml.safe_load((root / "config/prometheus/rules/tenancy.yml").read_text())
record_names = []
for group in rules["groups"]:
    for rule in group["rules"]:
        if "record" in rule:
            record_names.append(rule["record"])
if alerts.get("recording_rule_names") != record_names:
    errors.append("attach grafana recording_rule_names drifted from tenancy.yml")
for line_name, items in (alerts.get("alerts") or {}).items():
    if not items:
        errors.append(f"attach grafana alerts missing {line_name}")
    for item in items:
        for name in record_names:
            if name in item["expr"]:
                errors.append(f"{item['name']} still references recording rule {name}")
outputs = (root / "deploy/terraform/stacks/attach-existing/outputs.tf").read_text()
if "recording_rules_created_remotely" not in outputs or "prometheus_tenancy_rules" not in outputs:
    errors.append("attach stack does not output the tenancy rule artifact")
workloads_k = (root / "deploy/kubernetes/agent-workloads/kustomization.yaml").read_text()
if "demo-app.yaml" not in workloads_k or "business-workloads.yaml" not in workloads_k:
    errors.append("agent-workloads kustomization is not the generated demo set")
agent_k = (root / "deploy/kubernetes/agent/kustomization.yaml").read_text()
if "business-workloads.yaml" in agent_k or "demo-app.yaml" in agent_k:
    errors.append("default agent kustomization installs demo workloads")
for path in root.rglob("*"):
    if not path.is_file() or any(part.startswith(".") or part == ".terraform" for part in path.parts):
        continue
    if path.suffix in {".pem", ".crt", ".key"}:
        errors.append(f"certificate-like file committed: {path}")
        continue
    if path.stat().st_size > 1_000_000:
        continue
    try:
        blob = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    markers = ("BEGIN " + "CERTIFICATE", "BEGIN " + "PRIVATE KEY")
    if any(marker in blob for marker in markers):
        errors.append(f"PEM material committed: {path}")

agent = (root / "deploy/kubernetes/agent/kustomization.yaml").read_text()
if "count: 2" not in agent:
    errors.append("workload collector replica count is not 2")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print("northwind local render and tenant exemplar mapping ok")
PY

note "image pins"
python3 - <<'PY'
import pathlib, sys
root = pathlib.Path(".")
pins = {}
for line in (root / "deploy/images.env").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    pins[key] = value
compose = (root / "deploy/docker-compose/docker-compose.yml").read_text()
k8s = "\n".join(path.read_text() for path in (root / "deploy/kubernetes").rglob("*.yaml"))
docker = (root / "examples/demo-app/Dockerfile").read_text()
missing = []
for key, value in pins.items():
    if key == "DEMO_BASE_IMAGE":
        if value not in docker:
            missing.append(f"{key}={value} missing from demo Dockerfile")
        continue
    if value not in compose:
        missing.append(f"{key}={value} missing from docker-compose.yml")
    if value not in k8s:
        missing.append(f"{key}={value} missing from kubernetes manifests")
if missing:
    print("\n".join(missing))
    sys.exit(1)
print(f"{len(pins)} image pins present")
PY

note "yaml and json"
python3 - <<'PY'
import json, pathlib, sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

root = pathlib.Path(".")
errors = []
for path in list(root.rglob("*.yml")) + list(root.rglob("*.yaml")):
    if any(part.startswith(".") for part in path.parts):
        continue
    try:
        list(yaml.safe_load_all(path.read_text()))
    except Exception as exc:
        errors.append(f"{path}: {exc}")
for path in root.rglob("*.json"):
    if any(part.startswith(".") for part in path.parts):
        continue
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        errors.append(f"{path}: {exc}")
        continue
    if "dashboards" in path.parts:
        for key in ("uid", "title", "schemaVersion", "panels"):
            if key not in data:
                errors.append(f"{path}: missing {key}")
        if path.name in {
            "infrastructure.json", "middleware.json", "application.json",
            "business.json", "meta.json",
        }:
            names = [item.get("name") for item in data.get("templating", {}).get("list", [])]
            if "cluster" not in names:
                errors.append(f"{path}: missing cluster template variable")
            blob = json.dumps(data)
            if 'cluster=\\"$cluster\\"' not in blob and 'cluster="$cluster"' not in blob:
                errors.append(f"{path}: queries do not filter cluster")
        for panel in data.get("panels", []):
            ds = panel.get("datasource") or {}
            uid = ds.get("uid") if isinstance(ds, dict) else None
            allowed = {
                "prometheus", "loki", "tempo", "pyroscope", "alertmanager", None, "-- Grafana --"
            }
            if isinstance(ds, dict) and uid not in allowed and not (
                isinstance(uid, str)
                and (
                    uid.startswith("loki-")
                    or uid.startswith("tempo-")
                    or uid.startswith("prometheus-")
                    or uid.startswith("pyroscope-")
                )
            ):
                errors.append(f"{path}: panel {panel.get('id')} datasource uid {uid}")
        if path.name in {"toc-line.json", "tob-line.json", "application.json", "business.json"}:
            names = [item.get("name") for item in data.get("templating", {}).get("list", [])]
            blob = json.dumps(data)
            if "tenant" not in names and "tenant" not in blob:
                errors.append(f"{path}: missing tenant")
            if path.name == "toc-line.json" and 'business_line=\\"toc\\"' not in blob and 'business_line="toc"' not in blob:
                errors.append(f"{path}: ToC dashboard does not pin business_line")
            if path.name == "tob-line.json":
                tenant_var = next((item for item in data.get("templating", {}).get("list", []) if item.get("name") == "tenant"), {})
                if tenant_var.get("includeAll") or tenant_var.get("multi"):
                    errors.append(f"{path}: tenant variable must be single-select")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("yaml and dashboard json parsed")
PY

note "alloy syntax"
if command -v alloy >/dev/null 2>&1; then
  alloy fmt --test "$root/config/alloy/config.alloy" || die "alloy fmt local"
  alloy fmt --test "$root/config/alloy/config.k8s.alloy" || die "alloy fmt k8s"
  alloy fmt --test "$root/config/alloy/config.workload.alloy" || die "alloy fmt workload"
  # Remote-write URLs and the cluster label are read from the environment.
  export CLUSTER_NAME=local
  export INGEST_TOKEN=dev-ingest-token
  export PROMETHEUS_REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write
  export LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push
  # Workload alloy reads these. Empty is the platform path: labels are not stamped.
  export TENANT="${TENANT-}"
  export BUSINESS_LINE="${BUSINESS_LINE-}"
  export ORG_ID="${ORG_ID-}"
  alloy validate "$root/config/alloy/config.alloy" || die "alloy validate local"
  # Kubernetes config reads NODE_NAME at runtime. Validate with it set.
  NODE_NAME=validate-node alloy validate "$root/config/alloy/config.k8s.alloy" || die "alloy validate k8s"
  NODE_NAME=validate-node alloy validate "$root/config/alloy/config.workload.alloy" || die "alloy validate workload"
else
  die "alloy binary not found"
fi

note "collector config"
if command -v otelcol-contrib >/dev/null 2>&1; then
  # The collector config has no token default. Validate with the local placeholder.
  export INGEST_TOKEN=dev-ingest-token
  otelcol-contrib validate --config "$root/config/otel-collector/config.yaml" --feature-gates service.profilesSupport || die "otelcol validate"
else
  die "otelcol-contrib not found"
fi

note "prometheus"
if command -v promtool >/dev/null 2>&1; then
  # prometheus.yml points rule_files at /etc/prometheus/rules, which exists in
  # the container, not on the host. check rules reads the files directly.
  mapfile -t rule_files < <(find "$root/config/prometheus/rules" -maxdepth 1 -type f -name '*.yml' | sort)
  promtool check rules "${rule_files[@]}" || die "promtool check rules"
  promtool test rules "$root/config/prometheus/tests/alerts_test.yml" || die "promtool test rules"
else
  die "promtool not found"
fi

note "alertmanager"
if command -v amtool >/dev/null 2>&1; then
  amtool check-config "$root/config/alertmanager/alertmanager.yml" || die "amtool check-config"
else
  die "amtool not found"
fi

note "alert routing"
python3 - <<'PY'
import os
import pathlib
import subprocess
import sys

import yaml

root = pathlib.Path(".")
errors = []
am = (root / "config/alertmanager/alertmanager.yml").read_text()
if "intentionally unconfigured" not in am:
    errors.append("alertmanager.yml does not say paging is intentionally unconfigured")
if "alerts.example.invalid" in am or "\n    webhook_configs:" in "\n" + am:
    errors.append("committed alertmanager.yml still has a webhook")
for key in ("cluster", "business_line", "tenant", "alertname"):
    if key not in am.split("group_by:", 1)[1].split("group_wait", 1)[0]:
        errors.append(f"alertmanager group_by missing {key}")
contacts = (root / "config/grafana/provisioning/alerting/contact-points.yaml").read_text()
policies = (root / "config/grafana/provisioning/alerting/policies.yaml").read_text()
if "intentionally unconfigured" not in contacts or "alerts.example.invalid" in contacts:
    errors.append("grafana contact point is not the unconfigured receiver")
if "receivers: []" not in contacts:
    errors.append("grafana contact point still has a delivery receiver")
for key in ("cluster", "business_line", "tenant", "alertname"):
    if f"- {key}" not in policies:
        errors.append(f"grafana policy group_by missing {key}")
debug = (root / "docs/debugging.md").read_text()
for rules_path in (
    root / "config/prometheus/rules/alerts.yml",
    root / "config/prometheus/rules/tenancy.yml",
):
    document = yaml.safe_load(rules_path.read_text())
    for group in document["groups"]:
        for rule in group["rules"]:
            if "alert" not in rule:
                continue
            name = rule["alert"]
            url = (rule.get("annotations") or {}).get("runbook_url")
            want = f"docs/debugging.md#alert-{name}"
            if url != want:
                errors.append(f"{name} runbook_url is {url!r}, want {want}")
            if f'id="alert-{name}"' not in debug:
                errors.append(f"docs/debugging.md missing anchor alert-{name}")
env = dict(os.environ)
env.update({
    "ALERT_RENDER_ONLY": "1",
    "ALERTMANAGER_CONFIG_SRC": str(root / "config/alertmanager/alertmanager.yml"),
    "ALERTMANAGER_CONFIG_DST": "/tmp/alertmanager-paging.yml",
    "ALERT_WEBHOOK_URL": "http://alerts.example.invalid/hook",
})
rendered = subprocess.check_output(["sh", str(root / "config/alertmanager/entrypoint.sh")], env=env, text=True)
if "http://alerts.example.invalid/hook" not in rendered:
    errors.append("alertmanager entrypoint did not attach the webhook")
if rendered.count("webhook_configs:") != 2:
    errors.append("alertmanager entrypoint did not attach critical and warning webhooks")
env["ALERT_WEBHOOK_URL"] = ""
env["ALERTMANAGER_CONFIG_DST"] = "/tmp/alertmanager-quiet.yml"
quiet = subprocess.check_output(["sh", str(root / "config/alertmanager/entrypoint.sh")], env=env, text=True)
if "\n    webhook_configs:" in "\n" + quiet or "alerts.example.invalid" in quiet:
    errors.append("empty ALERT_WEBHOOK_URL still renders a webhook")
env.update({
    "GRAFANA_ALERTING_SRC": str(root / "config/grafana/provisioning/alerting"),
    "GRAFANA_ALERTING_DST": "/tmp/grafana-alerting-on",
    "ALERT_WEBHOOK_URL": "http://alerts.example.invalid/hook",
})
graf = subprocess.check_output(["sh", str(root / "config/grafana/provisioning/alerting/render-alerting.sh")], env=env, text=True)
if "http://alerts.example.invalid/hook" not in graf or '["severity", "=", "critical"]' not in graf:
    errors.append("grafana renderer did not route critical to the webhook")
for key in ("cluster", "business_line", "tenant", "alertname"):
    if f"- {key}" not in graf:
        errors.append(f"rendered grafana policy missing {key}")
env["ALERT_WEBHOOK_URL"] = ""
env["GRAFANA_ALERTING_DST"] = "/tmp/grafana-alerting-off"
off = subprocess.check_output(["sh", str(root / "config/grafana/provisioning/alerting/render-alerting.sh")], env=env, text=True)
if "alerts.example.invalid" in off or "alert-webhook" in off:
    errors.append("empty ALERT_WEBHOOK_URL still renders a grafana webhook")
alloy = (root / "config/alloy/config.workload.alloy").read_text()
if "otelcol.auth.bearer" not in alloy or "otelcol.auth.bearer.ingest.handler" not in alloy:
    errors.append("workload alloy OTLP receiver has no bearer authenticator")
policy = (root / "deploy/kubernetes/base/networkpolicy.yaml").read_text()
if "egress:\n    - {}" in policy or "\n    - {}\n" in policy:
    errors.append("networkpolicy still has an open egress rule")
if "port: 3000" in policy or "port: 8080" in policy:
    errors.append("networkpolicy still publishes Grafana or demo ports")
for port in ("443", "4317", "4318"):
    if f"port: {port}" not in policy:
        errors.append(f"networkpolicy missing egress/ingress port {port}")
if "observability.platform/otlp-client" not in policy:
    errors.append("networkpolicy has no labeled OTLP source")
if "kubernetes.io/metadata.name: observability" not in policy:
    errors.append("networkpolicy does not limit ingress to the observability namespace")
providers = (root / "deploy/terraform/stacks/platform/providers.tf").read_text()
if 'alias          = "prod_a"' in providers or "binding_prod_a" in (root / "deploy/terraform/stacks/platform/main.tf").read_text():
    errors.append("adding a cluster still requires a hardcoded provider alias")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("alert routing, alloy auth, and networkpolicy checks ok")
PY
amtool check-config /tmp/alertmanager-paging.yml || die "amtool check-config paging render"

note "loki"
if command -v loki >/dev/null 2>&1; then
  loki -config.file="$root/config/loki/loki.yaml" -verify-config || die "loki verify-config"
else
  die "loki binary not found"
fi

note "kustomize"
if command -v kustomize >/dev/null 2>&1; then
  # ConfigMaps are generated from /config, which lives outside the kustomize
  # root so Compose and Kubernetes share one file. That requires this flag.
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/overlays/dev" >/tmp/observability-dev.yaml || die "kustomize dev"
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/overlays/prod" >/tmp/observability-prod.yaml || die "kustomize prod"
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/agent" >/tmp/observability-agent.yaml || die "kustomize agent"
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/agent-workloads" >/tmp/observability-agent-workloads.yaml || die "kustomize agent workloads"
  python3 - <<'PY'
from pathlib import Path
text = Path("/tmp/observability-dev.yaml").read_text()
needles = [
    "otel-collector-config",
    "prometheus.yml",
    "alertmanager.yml",
    "loki.yaml",
    "tempo.yaml",
    "config.k8s.alloy",
    "datasources.yaml",
    "overview.json",
    "infrastructure.json",
    "middleware.json",
    "application.json",
    "business.json",
    "meta.json",
    "node-exporter",
    "redis-exporter",
    "postgres-exporter",
    "nginx-exporter",
    "kafka-exporter",
    "kube-state-metrics",
    "kind: Deployment",
    "kind: DaemonSet",
]
missing = [n for n in needles if n not in text]
if missing:
    raise SystemExit("kustomize output missing: " + ", ".join(missing))
if "CLUSTER_NAME: local" not in text:
    raise SystemExit("central overlay missing CLUSTER_NAME=local endpoints")
if "dev-ingest-token" not in text:
    raise SystemExit("dev overlay missing the local ingest placeholder")
if "tob-admin-northwind" not in text or "tob-billing-northwind" not in text:
    raise SystemExit("dev overlay missing northwind workloads")

def deployment_replicas(blob, name):
    chunks = blob.split("---\n")
    for chunk in chunks:
        if f"kind: Deployment\n" in chunk and f"\n  name: {name}\n" in chunk:
            for line in chunk.splitlines():
                if line.startswith("  replicas:"):
                    return int(line.split(":", 1)[1].strip())
    return None

for name in ("tob-admin-northwind", "tob-billing-northwind"):
    if deployment_replicas(text, name) != 1:
        raise SystemExit(f"dev {name} replicas are not 1")
prod_text = Path("/tmp/observability-prod.yaml").read_text()
if "dev-ingest-token" in prod_text:
    raise SystemExit("prod render contains the dev ingest placeholder")
for name in ("tob-admin-northwind", "tob-billing-northwind"):
    if deployment_replicas(prod_text, name) != 1:
        raise SystemExit(f"prod {name} replicas are not 1")
for name in ("prometheus", "loki", "tempo", "pyroscope"):
    if deployment_replicas(text, name) != 1 or deployment_replicas(prod_text, name) != 1:
        raise SystemExit(f"{name} is not a single replica")
agent_text = Path("/tmp/observability-agent.yaml").read_text()
if deployment_replicas(agent_text, "otel-collector") != 2:
    raise SystemExit("workload otel-collector replicas are not 2")
if deployment_replicas(text, "otel-collector") != 1:
    raise SystemExit("central otel-collector should stay at 1 replica")
agent = Path("/tmp/observability-agent.yaml").read_text()
missing_agent = [n for n in (
    "kind: DaemonSet",
    "otel-collector",
    "node-exporter",
    "kube-state-metrics",
    "observability-endpoints",
    'prometheus.scrape \\"node_exporter\\"',
    "external_labels",
) if n not in agent]
if "\n  name: prometheus\n" in agent:
    missing_agent.append("agent overlay includes central prometheus")
if "\n  name: demo-app\n" in agent or "\n  name: toc-checkout\n" in agent:
    missing_agent.append("default agent overlay includes demo workloads")
workloads = Path("/tmp/observability-agent-workloads.yaml").read_text()
for name in ("demo-app", "toc-checkout", "tob-admin-acme", "tob-billing-acme", "tob-admin-northwind", "tob-billing-northwind"):
    if f"\n  name: {name}\n" not in workloads:
        missing_agent.append(f"agent-workloads missing {name}")
if "key: PYROSCOPE_HTTP_URL" not in workloads:
    missing_agent.append("agent-workloads demo does not read PYROSCOPE_HTTP_URL")
if missing_agent:
    raise SystemExit("agent overlay problem: " + ", ".join(missing_agent))
print("kustomize overlays rendered")
PY
  python3 - <<'PY'
import pathlib, sys
root = pathlib.Path(".")
kust = (root / "deploy/kubernetes/base/kustomization.yaml").read_text()
missing = []
for path in (root / "config/grafana/dashboards").glob("*.json"):
    if path.name not in kust:
        missing.append(path.name)
if missing:
    print("dashboards missing from kustomization: " + ", ".join(missing))
    sys.exit(1)
business = (root / "examples/demo-app/src/demo_app/business.py").read_text()
collector = (root / "config/otel-collector/config.yaml").read_text()
for token in ("web", "api", "card", "wallet", "anonymous", "authenticated"):
    if f'"{token}"' not in business or f'"{token}"' not in collector:
        missing.append(token)
if missing:
    print("business allow-list missing from app or collector: " + ", ".join(missing))
    sys.exit(1)
print("dashboards mounted and business allow-list matches")
PY
else
  die "kustomize not found"
fi

note "compose config (optional render; a skip does not validate compose)"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$root/deploy/docker-compose/docker-compose.yml" -f "$root/deploy/docker-compose/businesses.yml" config >/tmp/observability-compose.yml || die "docker compose config"
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "$root/deploy/docker-compose/docker-compose.yml" -f "$root/deploy/docker-compose/businesses.yml" config >/tmp/observability-compose.yml || die "docker-compose config"
else
  echo "SKIP compose render: docker CLI is not installed. Compose files were not validated."
fi

note "demo unit tests"
PYTHONPATH="$root/examples/demo-app/src" python3 -m unittest discover -s "$root/examples/demo-app/tests" -q || die "demo unit tests"
python3 -m compileall -q "$root/examples/demo-app/src" || die "compileall"

note "terraform"
bash "$root/scripts/terraform-check.sh" || die "terraform validate"

if [[ "$fail" -ne 0 ]]; then
  echo "config-check failed" >&2
  exit 1
fi
echo "config-check passed"
