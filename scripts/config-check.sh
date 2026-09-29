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
        for panel in data.get("panels", []):
            ds = panel.get("datasource") or {}
            if isinstance(ds, dict) and ds.get("uid") not in {
                "prometheus", "loki", "tempo", "pyroscope", "alertmanager", None, "-- Grafana --"
            }:
                errors.append(f"{path}: panel {panel.get('id')} datasource uid {ds.get('uid')}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("yaml and dashboard json parsed")
PY

note "alloy syntax"
if command -v alloy >/dev/null 2>&1; then
  alloy fmt --test "$root/config/alloy/config.alloy" || die "alloy fmt local"
  alloy fmt --test "$root/config/alloy/config.k8s.alloy" || die "alloy fmt k8s"
  alloy validate "$root/config/alloy/config.alloy" || die "alloy validate local"
  # Kubernetes config reads NODE_NAME at runtime. Validate with it set.
  NODE_NAME=validate-node alloy validate "$root/config/alloy/config.k8s.alloy" || die "alloy validate k8s"
else
  warn "alloy binary not found; skipped river validation"
fi

note "collector config"
if command -v otelcol-contrib >/dev/null 2>&1; then
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
  docker compose -f "$root/deploy/docker-compose/docker-compose.yml" config >/tmp/observability-compose.yml || die "docker compose config"
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose -f "$root/deploy/docker-compose/docker-compose.yml" config >/tmp/observability-compose.yml || die "docker-compose config"
else
  warn "docker compose CLI not found; skipped compose config"
fi

note "demo unit tests"
PYTHONPATH="$root/examples/demo-app/src" python3 -m unittest discover -s "$root/examples/demo-app/tests" -q || die "demo unit tests"
python3 -m compileall -q "$root/examples/demo-app/src" || die "compileall"

if [[ "$fail" -ne 0 ]]; then
  echo "config-check failed" >&2
  exit 1
fi
echo "config-check passed"
