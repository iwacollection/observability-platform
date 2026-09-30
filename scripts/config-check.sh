#!/usr/bin/env bash
# Static checks for the observability configs. Missing optional binaries are
# reported; promtool, amtool, and a YAML/JSON parser are required.
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

dev_k = (root / "deploy/kubernetes/overlays/dev/kustomization.yaml").read_text()
for name in ("replicas-tob-admin-northwind.yaml", "replicas-tob-billing-northwind.yaml"):
    if name not in dev_k:
        errors.append(f"dev overlay missing {name}")
    body = (root / "deploy/kubernetes/overlays/dev" / name).read_text()
    if "replicas: 1" not in body:
        errors.append(f"{name} is not replicas 1")

base = (root / "deploy/kubernetes/base/business-workloads.yaml").read_text()
# Prod inherits the base count. Northwind stays smaller than dev.
if "name: tob-admin-northwind" not in base or "name: tob-billing-northwind" not in base:
    errors.append("base workloads missing northwind")

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
if "tenant_id=org_id" not in telemetry:
    errors.append("demo SDK does not send the Pyroscope org id")

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
  warn "alloy binary not found; skipped river validation"
fi

note "collector config"
if command -v otelcol-contrib >/dev/null 2>&1; then
  # The collector config has no token default. Validate with the local placeholder.
  export INGEST_TOKEN=dev-ingest-token
  otelcol-contrib validate --config "$root/config/otel-collector/config.yaml" --feature-gates service.profilesSupport || die "otelcol validate"
else
  warn "otelcol-contrib not found; skipped collector validate"
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

note "loki"
if command -v loki >/dev/null 2>&1; then
  loki -config.file="$root/config/loki/loki.yaml" -verify-config || die "loki verify-config"
else
  warn "loki binary not found; skipped"
fi

note "kustomize"
if command -v kustomize >/dev/null 2>&1; then
  # ConfigMaps are generated from /config, which lives outside the kustomize
  # root so Compose and Kubernetes share one file. That requires this flag.
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/overlays/dev" >/tmp/observability-dev.yaml || die "kustomize dev"
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/overlays/prod" >/tmp/observability-prod.yaml || die "kustomize prod"
  kustomize build --load-restrictor LoadRestrictionsNone "$root/deploy/kubernetes/agent" >/tmp/observability-agent.yaml || die "kustomize agent"
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
    if deployment_replicas(prod_text, name) != 0:
        raise SystemExit(f"prod {name} replicas are not 0")
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

note "compose config"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$root/deploy/docker-compose/docker-compose.yml" -f "$root/deploy/docker-compose/businesses.yml" config >/tmp/observability-compose.yml || die "docker compose config"
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "$root/deploy/docker-compose/docker-compose.yml" -f "$root/deploy/docker-compose/businesses.yml" config >/tmp/observability-compose.yml || die "docker-compose config"
else
  warn "docker compose CLI not found; skipped compose config"
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
