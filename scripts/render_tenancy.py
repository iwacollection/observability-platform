#!/usr/bin/env python3
"""Render tenant-specific config from config/tenancy.yaml.

The yaml file is the catalog. This script writes the collector routing
block, Grafana org datasources, Prometheus tenancy rules, Compose services,
and Kubernetes workloads. `make render-tenancy` updates the tree.
`make config-check` runs `--check` and fails if the tree drifted.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TENANCY_PATH = ROOT / "config" / "tenancy.yaml"
COLLECTOR_PATH = ROOT / "config" / "otel-collector" / "config.yaml"


def load_tenancy() -> dict:
    data = yaml.safe_load(TENANCY_PATH.read_text())
    toc = data["business_lines"]["toc"]
    tob = data["business_lines"]["tob"]
    if toc["kind"] != "toc" or tob["kind"] != "tob":
        raise SystemExit("business_lines.toc.kind and tob.kind are required")
    if toc["tenant"] != "consumer" or toc["org_id"] != "toc":
        raise SystemExit("ToC tenant must be consumer and org_id toc")
    if len(toc["services"]) < 2 or len(tob["services"]) < 2:
        raise SystemExit("each business line needs at least two services")
    if len(tob["tenants"]) < 2:
        raise SystemExit("ToB needs a bounded allow-list of at least two tenants")
    ids = []
    for tenant in tob["tenants"]:
        tid = tenant["id"]
        ids.append(tid)
        if tenant["org_id"] != f"tob-{tid}":
            raise SystemExit(f"org_id for {tid} must be tob-{tid}")
        if tid in {"consumer"} or any(ch in tid for ch in "._/ "):
            raise SystemExit(f"refusing tenant id {tid}")
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate ToB tenant id")
    if "acme" not in ids or "northwind" not in ids:
        raise SystemExit("example allow-list must keep acme and northwind")
    for tenant in tob["tenants"]:
        if tenant["id"] not in {"acme", "northwind"}:
            continue
        if not tenant.get("compose"):
            raise SystemExit(f"{tenant['id']} must run in local Compose (compose: true)")
        dev_replicas = int(tenant.get("dev_replicas", tenant.get("replicas", 0)))
        if dev_replicas < 1:
            raise SystemExit(f"{tenant['id']} must run in the dev overlay (dev_replicas or replicas >= 1)")
        for service in tob["services"]:
            if service["name"] not in tenant.get("host_ports", {}):
                raise SystemExit(f"{tenant['id']} missing host port for {service['name']}")
    return data


def statements(data: dict) -> list[str]:
    tenants = data["business_lines"]["tob"]["tenants"]
    not_allowed = " and ".join(
        f'attributes["tenant"] != "{tenant["id"]}"' for tenant in tenants
    )
    lines = [
        'set(attributes["tenant"], "consumer") where attributes["business_line"] == "toc"',
        f'set(attributes["tenant"], "rejected") where attributes["business_line"] == "tob" and {not_allowed}',
        'set(attributes["business_line"], "rejected") where attributes["business_line"] != "toc" and attributes["business_line"] != "tob"',
        'set(attributes["tenant"], "rejected") where attributes["business_line"] == "rejected"',
        'set(attributes["org_id"], "toc") where attributes["business_line"] == "toc"',
    ]
    for tenant in tenants:
        lines.append(
            'set(attributes["org_id"], "%s") where attributes["business_line"] == "tob" and attributes["tenant"] == "%s"'
            % (tenant["org_id"], tenant["id"])
        )
    lines.append('set(attributes["org_id"], "rejected") where attributes["org_id"] == nil')
    for key in ("user.id", "order.id", "customer.id", "enduser.id"):
        lines.append(f'delete_key(attributes, "{key}")')
    return lines


def orgs(data: dict) -> list[tuple[str, str]]:
    """(pipeline suffix, org id) including the rejected sink."""
    rows = [("toc", data["business_lines"]["toc"]["org_id"])]
    for tenant in data["business_lines"]["tob"]["tenants"]:
        rows.append((tenant["id"].replace("-", "_"), tenant["org_id"]))
    rows.append(("rejected", data["rejected_org_id"]))
    return rows


def connectors_yaml(data: dict) -> str:
    def table(signal: str) -> str:
        chunks = []
        for suffix, org in orgs(data):
            chunks.append(
                "\n".join(
                    [
                        "      - context: resource",
                        f'        statement: route() where attributes["org_id"] == "{org}"',
                        f"        pipelines: [{signal}/{suffix}]",
                    ]
                )
            )
        return "\n".join(chunks)

    return "\n".join(
        [
            "  routing/logs:",
            "    default_pipelines: [logs/rejected]",
            "    error_mode: ignore",
            "    table:",
            table("logs"),
            "  routing/traces:",
            "    default_pipelines: [traces/rejected]",
            "    error_mode: ignore",
            "    table:",
            table("traces"),
            "",
        ]
    )


def exporters_yaml(data: dict) -> str:
    blocks = []
    for suffix, org in orgs(data):
        blocks.append(
            "\n".join(
                [
                    f"  otlphttp/loki_{suffix}:",
                    "    endpoint: ${env:LOKI_OTLP_ENDPOINT:-http://loki:3100/otlp}",
                    "    auth:",
                    "      authenticator: bearertokenauth",
                    "    headers:",
                    f"      X-Scope-OrgID: {org}",
                    "    tls:",
                    "      insecure: ${env:OTEL_EXPORTER_TLS_INSECURE:-false}",
                    "      ca_file: ${env:OTEL_EXPORTER_TLS_CA_FILE:-}",
                    f"  otlp/tempo_{suffix}:",
                    "    endpoint: ${env:TEMPO_OTLP_ENDPOINT:-tempo:4317}",
                    "    auth:",
                    "      authenticator: bearertokenauth",
                    "    headers:",
                    f"      X-Scope-OrgID: {org}",
                    "    tls:",
                    "      insecure: ${env:OTEL_EXPORTER_TLS_INSECURE:-false}",
                    "      ca_file: ${env:OTEL_EXPORTER_TLS_CA_FILE:-}",
                ]
            )
        )
    return "\n".join(blocks) + "\n"


def pipelines_yaml(data: dict) -> str:
    blocks = []
    for suffix, _org in orgs(data):
        blocks.append(
            "\n".join(
                [
                    f"    logs/{suffix}:",
                    "      receivers: [routing/logs]",
                    f"      exporters: [otlphttp/loki_{suffix}]",
                    f"    traces/{suffix}:",
                    "      receivers: [routing/traces]",
                    f"      exporters: [otlp/tempo_{suffix}]",
                ]
            )
        )
    return "\n".join(blocks) + "\n"


def statements_yaml(data: dict) -> str:
    return "\n".join(f"          - {line}" for line in statements(data)) + "\n"


def splice(text: str, name: str, body: str) -> str:
    start = f"# TENANCY:{name}\n"
    end = f"# TENANCY:{name}:end"
    parts: list[str] = []
    pos = 0
    found = 0
    while True:
        at = text.find(start, pos)
        if at < 0:
            parts.append(text[pos:])
            break
        stop = text.find(end, at)
        if stop < 0:
            raise SystemExit(f"unterminated marker {name}")
        parts.append(text[pos : at + len(start)])
        block = body if body.endswith("\n") else body + "\n"
        parts.append(block)
        pos = stop
        found += 1
    if found == 0:
        raise SystemExit(f"missing marker {name} in collector config")
    return "".join(parts)


def render_collector(data: dict, check: bool) -> None:
    original = COLLECTOR_PATH.read_text()
    text = original
    text = splice(text, "statements", statements_yaml(data))
    text = splice(text, "connectors", connectors_yaml(data))
    text = splice(text, "exporters", exporters_yaml(data))
    text = splice(text, "pipelines", pipelines_yaml(data))
    if check and text != original:
        raise SystemExit("collector tenancy block is stale; run make render-tenancy")
    if not check:
        COLLECTOR_PATH.write_text(text)


# Grafana provisioning expands this. The value is the whole header, so the
# env var must already include the "Bearer " prefix. See INGEST_AUTHORIZATION.
AUTH_HEADER_ENV = "$__env{INGEST_AUTHORIZATION}"


def datasource(name: str, uid: str, kind: str, url: str, org: str | None, extra: dict | None = None) -> dict:
    json_data: dict = {}
    secure: dict = {}
    if org:
        json_data["httpHeaderName1"] = "X-Scope-OrgID"
        secure["httpHeaderValue1"] = org
        json_data["httpHeaderName2"] = "Authorization"
        secure["httpHeaderValue2"] = AUTH_HEADER_ENV
    else:
        json_data["httpHeaderName1"] = "Authorization"
        secure["httpHeaderValue1"] = AUTH_HEADER_ENV
    payload = {
        "name": name,
        "uid": uid,
        "type": kind,
        "access": "proxy",
        "url": url,
        "editable": False,
        "jsonData": json_data,
        "secureJsonData": secure,
    }
    if extra:
        payload["jsonData"].update(extra)
    return payload


def prometheus_for_tempo(name: str, uid: str, tempo_uid: str) -> dict:
    return datasource(
        name,
        uid,
        "prometheus",
        "http://prometheus:9090",
        None,
        {
            "timeInterval": "15s",
            "httpMethod": "POST",
            "exemplarTraceIdDestinations": [
                {"name": "trace_id", "datasourceUid": tempo_uid},
            ],
        },
    )


def render_datasources(data: dict, check: bool) -> None:
    path = ROOT / "config" / "grafana" / "provisioning" / "datasources" / "tenancy.yaml"
    items = []
    items.append(
        datasource(
            "Loki platform",
            "loki-platform",
            "loki",
            "http://loki:3100",
            data["platform_org_id"],
        )
    )
    items.append(
        datasource(
            "Loki rejected",
            "loki-rejected",
            "loki",
            "http://loki:3100",
            data["rejected_org_id"],
        )
    )
    items.append(
        datasource(
            "Tempo rejected",
            "tempo-rejected",
            "tempo",
            "http://tempo:3200",
            data["rejected_org_id"],
            {
                "httpMethod": "GET",
                "tracesToProfiles": {"datasourceUid": "pyroscope-rejected"},
                "tracesToMetrics": {"datasourceUid": "prometheus"},
                "serviceMap": {"datasourceUid": "prometheus"},
                "nodeGraph": {"enabled": True},
            },
        )
    )
    items.append(
        datasource(
            "Pyroscope platform",
            "pyroscope-platform",
            "grafana-pyroscope-datasource",
            "http://pyroscope:4040",
            data["platform_org_id"],
        )
    )
    items.append(
        datasource(
            "Pyroscope rejected",
            "pyroscope-rejected",
            "grafana-pyroscope-datasource",
            "http://pyroscope:4040",
            data["rejected_org_id"],
        )
    )
    for tenant in data["business_lines"]["tob"]["tenants"]:
        org = tenant["org_id"]
        tempo_uid = f"tempo-{org}"
        prom_uid = f"prometheus-{org}"
        pyro_uid = f"pyroscope-{org}"
        items.append(datasource(f"Loki {org}", f"loki-{org}", "loki", "http://loki:3100", org))
        items.append(
            datasource(
                f"Tempo {org}",
                tempo_uid,
                "tempo",
                "http://tempo:3200",
                org,
                {
                    "httpMethod": "GET",
                    "tracesToLogsV2": {
                        "datasourceUid": f"loki-{org}",
                        "filterByTraceID": True,
                        "filterBySpanID": False,
                    },
                    "tracesToProfiles": {"datasourceUid": pyro_uid},
                    "tracesToMetrics": {"datasourceUid": prom_uid},
                    "serviceMap": {"datasourceUid": prom_uid},
                    "nodeGraph": {"enabled": True},
                },
            )
        )
        items.append(
            datasource(
                f"Pyroscope {org}",
                pyro_uid,
                "grafana-pyroscope-datasource",
                "http://pyroscope:4040",
                org,
            )
        )
        # Same Prometheus URL as uid prometheus. The exemplar destination is
        # this tenant's Tempo datasource, not the ToC uid "tempo".
        items.append(prometheus_for_tempo(f"Prometheus {org}", prom_uid, tempo_uid))
    body = yaml.safe_dump({"apiVersion": 1, "datasources": items}, sort_keys=False)
    header = (
        "# Generated from config/tenancy.yaml by scripts/render_tenancy.py.\n"
        "# X-Scope-OrgID values are org ids from the allow-list, not credentials.\n"
        "# Authorization is Bearer $__env{INGEST_AUTHORIZATION}. Grafana expands\n"
        "# that at provisioning time. Do not put the token in this file.\n"
        "# prometheus-tob-<id> is the same Prometheus as uid prometheus. Its\n"
        "# exemplarTraceIdDestinations point at tempo-tob-<id>, not uid tempo.\n"
    )
    text = header + body
    write_or_check(path, text, check)


def tenant_regex(data: dict) -> str:
    ids = "|".join(tenant["id"] for tenant in data["business_lines"]["tob"]["tenants"])
    return ids


def tenancy_rules_text(data: dict) -> str:
    ids = tenant_regex(data)
    text = f"""# Generated from config/tenancy.yaml by scripts/render_tenancy.py.
# ToC rules select business_line=toc and tenant=consumer.
# ToB rules select business_line=tob and keep tenant in the aggregation,
# so acme and northwind are never added together and neither is added to ToC.
groups:
  - name: tenancy-recording
    interval: 30s
    rules:
      - record: toc:http_requests:rate5m
        expr: |
          sum by (cluster, tenant, business_line, service_name) (
            rate(http_server_request_duration_seconds_count{{business_line="toc",tenant="consumer",http_route!="/healthz"}}[5m])
          )

      - record: tob:http_requests:rate5m
        expr: |
          sum by (cluster, tenant, business_line, service_name) (
            rate(http_server_request_duration_seconds_count{{business_line="tob",tenant=~"{ids}",http_route!="/healthz"}}[5m])
          )

      - record: toc:payments:failure_ratio5m
        expr: |
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_payments_total{{business_line="toc",tenant="consumer",result="failure"}}[5m])
          )
          /
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_payments_total{{business_line="toc",tenant="consumer"}}[5m])
          )

      - record: tob:invoices:failure_ratio5m
        expr: |
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_invoices_total{{business_line="tob",tenant=~"{ids}",result="failure"}}[5m])
          )
          /
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_invoices_total{{business_line="tob",tenant=~"{ids}"}}[5m])
          )

      - record: tob:seats:active
        expr: |
          sum by (cluster, tenant, business_line, service_name, plan) (
            business_seats_active{{business_line="tob",tenant=~"{ids}"}}
          )

      - record: tob:seats:utilization
        expr: |
          sum by (cluster, tenant, business_line, service_name, plan) (
            business_seats_active{{business_line="tob",tenant=~"{ids}"}}
          )
          /
          clamp_min(
            sum by (cluster, tenant, business_line, service_name, plan) (
              business_seats_limit{{business_line="tob",tenant=~"{ids}"}}
            ),
            1
          )

      - record: tob:api_quota:utilization
        expr: |
          sum by (cluster, tenant, business_line, service_name, quota_class) (
            business_api_quota_used{{business_line="tob",tenant=~"{ids}"}}
          )
          /
          clamp_min(
            sum by (cluster, tenant, business_line, service_name, quota_class) (
              business_api_quota_limit{{business_line="tob",tenant=~"{ids}"}}
            ),
            1
          )

  - name: tenancy-alerts
    rules:
      - alert: TocPaymentFailureRatio
        expr: |
          toc:payments:failure_ratio5m > 0.1
          and
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_payments_total{{business_line="toc",tenant="consumer"}}[5m])
          ) > 0.05
        for: 5m
        labels:
          severity: warning
          layer: business
        annotations:
          runbook_url: "docs/debugging.md#alert-TocPaymentFailureRatio"
          summary: "ToC payment failure ratio is above 10%"
          description: "{{{{ $labels.cluster }}}} {{{{ $labels.tenant }}}} {{{{ $labels.service_name }}}} payment failures are above 10%."

      - alert: TobInvoiceFailureRatio
        expr: |
          tob:invoices:failure_ratio5m > 0.1
          and
          sum by (cluster, tenant, business_line, service_name) (
            rate(business_invoices_total{{business_line="tob",tenant=~"{ids}"}}[5m])
          ) > 0.05
        for: 5m
        labels:
          severity: warning
          layer: business
        annotations:
          runbook_url: "docs/debugging.md#alert-TobInvoiceFailureRatio"
          summary: "ToB invoice failure ratio is above 10%"
          description: "{{{{ $labels.cluster }}}} tenant {{{{ $labels.tenant }}}} {{{{ $labels.service_name }}}} invoice failures are above 10%."

      - alert: TobSeatSaturation
        expr: tob:seats:utilization > 0.9
        for: 10m
        labels:
          severity: warning
          layer: business
        annotations:
          runbook_url: "docs/debugging.md#alert-TobSeatSaturation"
          summary: "ToB seat utilization is above 90%"
          description: "{{{{ $labels.cluster }}}} tenant {{{{ $labels.tenant }}}} plan {{{{ $labels.plan }}}} is above 90% of the seat limit."

      - alert: TobApiQuotaHigh
        expr: tob:api_quota:utilization > 0.9
        for: 10m
        labels:
          severity: warning
          layer: business
        annotations:
          runbook_url: "docs/debugging.md#alert-TobApiQuotaHigh"
          summary: "ToB API quota utilization is above 90%"
          description: "{{{{ $labels.cluster }}}} tenant {{{{ $labels.tenant }}}} class {{{{ $labels.quota_class }}}} is above 90% of the quota."
"""
    # The f-string doubled braces so Prometheus keeps Go templates.
    return text.replace("{{{{", "{{").replace("}}}}", "}}")


def render_rules(data: dict, check: bool) -> None:
    path = ROOT / "config" / "prometheus" / "rules" / "tenancy.yml"
    write_or_check(path, tenancy_rules_text(data), check)


def render_attach_grafana_alerts(data: dict, check: bool) -> None:
    """Inline tenancy.yml into Grafana unified alerting.

    stacks/attach-existing cannot upload recording rules to a remote
    Prometheus without a live server. Grafana therefore evaluates the same
    expressions directly and must not mention recording-rule names.
    """
    document = yaml.safe_load(tenancy_rules_text(data))
    records: dict[str, str] = {}
    alerts: list[dict] = []
    for group in document["groups"]:
        for rule in group["rules"]:
            if "record" in rule:
                records[rule["record"]] = str(rule["expr"]).strip()
            elif "alert" in rule:
                alerts.append(rule)

    def inline(expr: str) -> str:
        rendered = str(expr).strip()
        for name in sorted(records, key=len, reverse=True):
            if name in rendered:
                rendered = rendered.replace(name, "(\n" + records[name] + "\n)")
        leftover = [name for name in records if name in rendered]
        if leftover:
            raise SystemExit("attach grafana expr still references " + ", ".join(leftover))
        return rendered

    grouped: dict[str, list[dict]] = {"toc": [], "tob": []}
    for rule in alerts:
        name = str(rule["alert"])
        bucket = "toc" if name.startswith("Toc") else "tob"
        grouped[bucket].append(
            {
                "name": name,
                "pending": str(rule["for"]),
                "summary": str(rule["annotations"]["summary"]),
                "expr": inline(rule["expr"]),
            }
        )
    if not grouped["toc"] or not grouped["tob"]:
        raise SystemExit("attach grafana alerts missing toc or tob")
    payload = {
        "recording_rules_created_remotely": False,
        "recording_rule_names": list(records),
        "note": (
            "Grafana evaluates these expressions directly. The recording-rule "
            "names are not created on the remote Prometheus. When the existing "
            "Prometheus is this repo's binary, mount config/prometheus/rules/tenancy.yml. "
            "stacks/platform already does. This stack does not upload rules."
        ),
        "alerts": grouped,
    }
    path = (
        ROOT
        / "deploy"
        / "terraform"
        / "stacks"
        / "attach-existing"
        / "generated"
        / "grafana-line-alerts.json"
    )
    write_or_check(path, json.dumps(payload, indent=2, ensure_ascii=False) + "\n", check)


def compose_service(name: str, service_name: str, role: str, line: str, tenant: str, host_port: int) -> str:
    return f"""  {name}:
    image: demo-app:local
    environment:
      OTEL_SERVICE_NAME: {service_name}
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317
      PYROSCOPE_HTTP_URL: http://pyroscope:4040
      INGEST_TOKEN: ${{INGEST_TOKEN:-dev-ingest-token}}
      DEPLOYMENT_ENVIRONMENT: local
      CLUSTER_NAME: local
      BUSINESS_LINE: {line}
      TENANT_ID: {tenant}
      SERVICE_ROLE: {role}
      DEMO_LISTEN_ADDR: 0.0.0.0:8080
      OTEL_METRIC_EXPORT_INTERVAL: "5000"
      OTEL_METRICS_EXEMPLAR_FILTER: trace_based
    ports:
      - "127.0.0.1:{host_port}:8080"
    depends_on:
      otel-collector:
        condition: service_started
      pyroscope:
        condition: service_started
    mem_limit: 256m
    restart: unless-stopped
"""


def render_compose(data: dict, check: bool) -> None:
    path = ROOT / "deploy" / "docker-compose" / "businesses.yml"
    blocks = [
        "# Generated from config/tenancy.yaml by scripts/render_tenancy.py.",
        "# Cluster is local. ToC api stays in docker-compose.yml as demo-app",
        "# so the existing :8080 path and nginx upstream keep working.",
        "services:",
    ]
    toc = data["business_lines"]["toc"]
    for service in toc["services"]:
        if service["compose_service"] == "demo-app":
            continue
        blocks.append(
            compose_service(
                service["compose_service"],
                service["name"],
                service["role"],
                "toc",
                toc["tenant"],
                service["host_port"],
            ).rstrip("\n")
        )
    for tenant in data["business_lines"]["tob"]["tenants"]:
        if not tenant.get("compose"):
            continue
        for service in data["business_lines"]["tob"]["services"]:
            host_port = tenant["host_ports"][service["name"]]
            blocks.append(
                compose_service(
                    f"{service['name']}-{tenant['id']}",
                    service["name"],
                    service["role"],
                    "tob",
                    tenant["id"],
                    host_port,
                ).rstrip("\n")
            )
    text = "\n".join(blocks) + "\n"
    write_or_check(path, text, check)


def k8s_workload(name: str, service_name: str, role: str, line: str, tenant: str, org: str, replicas: int) -> str:
    label = service_name
    return f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  labels:
    app.kubernetes.io/name: {label}
    observability.platform/business-line: {line}
    observability.platform/tenant: {tenant}
    observability.platform/org-id: {org}
spec:
  replicas: {replicas}
  selector:
    matchLabels:
      app.kubernetes.io/name: {name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {name}
        observability.platform/business-line: {line}
        observability.platform/tenant: {tenant}
        observability.platform/org-id: {org}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: demo-app:local
          imagePullPolicy: IfNotPresent
          env:
            - name: OTEL_SERVICE_NAME
              value: {service_name}
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector:4317
            - name: PYROSCOPE_HTTP_URL
              valueFrom:
                configMapKeyRef:
                  name: observability-endpoints
                  key: PYROSCOPE_HTTP_URL
            - name: INGEST_TOKEN
              valueFrom:
                secretKeyRef:
                  name: ingest-auth
                  key: token
            - name: DEPLOYMENT_ENVIRONMENT
              value: dev
            - name: CLUSTER_NAME
              valueFrom:
                configMapKeyRef:
                  name: observability-endpoints
                  key: CLUSTER_NAME
            - name: BUSINESS_LINE
              value: {line}
            - name: TENANT_ID
              value: {tenant}
            - name: SERVICE_ROLE
              value: {role}
            - name: DEMO_LISTEN_ADDR
              value: 0.0.0.0:8080
            - name: OTEL_METRIC_EXPORT_INTERVAL
              value: "5000"
            - name: OTEL_METRICS_EXEMPLAR_FILTER
              value: trace_based
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {{}}
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  labels:
    app.kubernetes.io/name: {name}
spec:
  selector:
    app.kubernetes.io/name: {name}
  ports:
    - name: http
      port: 8080
      targetPort: http
"""


def dev_replica_count(tenant: dict) -> int:
    if "dev_replicas" in tenant:
        return int(tenant["dev_replicas"])
    return int(tenant.get("replicas", 0))


def render_workloads(data: dict, check: bool) -> None:
    path = ROOT / "deploy" / "kubernetes" / "base" / "business-workloads.yaml"
    header = "\n".join(
        [
            "# Generated from config/tenancy.yaml by scripts/render_tenancy.py.",
            "# toc-api is deploy/kubernetes/base/demo-app.yaml (service demo-app).",
            "# replicas is the base and prod count. The dev overlay raises a",
            "# tenant when tenancy.yaml sets dev_replicas.",
        ]
    )
    docs = []
    prod_patches = []
    toc = data["business_lines"]["toc"]
    for service in toc["services"]:
        if service["compose_service"] == "demo-app":
            continue
        docs.append(
            k8s_workload(
                service["compose_service"],
                service["name"],
                service["role"],
                "toc",
                toc["tenant"],
                toc["org_id"],
                1,
            ).rstrip()
            + "\n"
        )
        prod_patches.append((service["compose_service"], "app"))
    for tenant in data["business_lines"]["tob"]["tenants"]:
        for service in data["business_lines"]["tob"]["services"]:
            deploy_name = f"{service['name']}-{tenant['id']}"
            docs.append(
                k8s_workload(
                    deploy_name,
                    service["name"],
                    service["role"],
                    "tob",
                    tenant["id"],
                    tenant["org_id"],
                    int(tenant.get("replicas", 0)),
                ).rstrip()
                + "\n"
            )
            prod_patches.append((deploy_name, "app"))
    text = header + "\n" + "---\n".join(docs)
    if not text.endswith("\n"):
        text += "\n"
    write_or_check(path, text, check)
    render_prod_patches(prod_patches, check)
    render_dev_replica_patches(data, check)


def render_dev_replica_patches(data: dict, check: bool) -> None:
    overlay = ROOT / "deploy" / "kubernetes" / "overlays" / "dev"
    names = []
    for tenant in data["business_lines"]["tob"]["tenants"]:
        if "dev_replicas" not in tenant:
            continue
        count = dev_replica_count(tenant)
        for service in data["business_lines"]["tob"]["services"]:
            deploy_name = f"{service['name']}-{tenant['id']}"
            names.append(deploy_name)
            body = f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: {deploy_name}
spec:
  replicas: {count}
"""
            write_or_check(overlay / f"replicas-{deploy_name}.yaml", body, check)
    kustom = overlay / "kustomization.yaml"
    original = kustom.read_text()
    block = "\n".join(f"  - path: replicas-{name}.yaml" for name in names)
    updated = splice(original, "patches", block + "\n")
    if check and updated != original:
        raise SystemExit("dev kustomization tenancy patches are stale; run make render-tenancy")
    if not check:
        kustom.write_text(updated)


def render_prod_patches(items: list[tuple[str, str]], check: bool) -> None:
    overlay = ROOT / "deploy" / "kubernetes" / "overlays" / "prod"
    names = []
    for deploy_name, container in items:
        names.append(deploy_name)
        body = f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: {deploy_name}
spec:
  template:
    spec:
      containers:
        - name: {container}
          env:
            - name: DEPLOYMENT_ENVIRONMENT
              value: prod
"""
        write_or_check(overlay / f"env-{deploy_name}.yaml", body, check)
    kustom = overlay / "kustomization.yaml"
    original = kustom.read_text()
    block = "\n".join(f"  - path: env-{name}.yaml" for name in names)
    updated = splice(original, "patches", block + "\n")
    if check and updated != original:
        raise SystemExit("prod kustomization tenancy patches are stale; run make render-tenancy")
    if not check:
        kustom.write_text(updated)


def panel(pid: int, title: str, expr: str, y: int, x: int = 0, w: int = 12, ds_uid: str = "prometheus", ds_type: str = "prometheus", exemplar: bool = False) -> dict:
    target = {
        "refId": "A",
        "datasource": {"type": ds_type, "uid": ds_uid},
        "expr": expr,
    }
    if exemplar:
        target["exemplar"] = True
    return {
        "id": pid,
        "type": "timeseries" if ds_type == "prometheus" else "logs",
        "title": title,
        "gridPos": {"h": 8, "w": w, "x": x, "y": y},
        "datasource": {"type": ds_type, "uid": ds_uid},
        "targets": [target],
    }


def cluster_var() -> dict:
    return {
        "name": "cluster",
        "label": "Cluster",
        "type": "custom",
        "query": "local,prod-a,prod-b",
        "includeAll": False,
        "multi": False,
        "current": {"selected": True, "text": "local", "value": "local"},
        "options": [
            {"selected": True, "text": "local", "value": "local"},
            {"selected": False, "text": "prod-a", "value": "prod-a"},
            {"selected": False, "text": "prod-b", "value": "prod-b"},
        ],
    }


def render_dashboards(data: dict, check: bool) -> None:
    ids = tenant_regex(data)
    directory = ROOT / "config" / "grafana" / "dashboards"
    toc_panels = [
        panel(1, "基础设施：节点 CPU", 'instance:node_cpu_utilization:ratio{cluster="$cluster"}', 0),
        panel(2, "中间件：Redis 存活", 'redis_up{cluster="$cluster"}', 0, 12),
        panel(3, "应用：ToC 请求速率", 'sum by (service_name) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="toc",tenant="consumer",http_route!="/healthz"}[5m]))', 8),
        panel(4, "应用：ToC 5xx 比例", 'sum by (service_name) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="toc",tenant="consumer",http_route!="/healthz",http_response_status_code=~"5.."}[5m])) / sum by (service_name) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="toc",tenant="consumer",http_route!="/healthz"}[5m]))', 8, 12),
        panel(5, "业务：ToC 支付失败比", 'toc:payments:failure_ratio5m{cluster="$cluster",business_line="toc",tenant="consumer"}', 16),
        panel(6, "业务：ToC 结账延迟 p95", 'business:checkout_duration:p95_5m{cluster="$cluster",business_line="toc",tenant="consumer"}', 16, 12),
        panel(7, "平台：Collector 队列", 'platform:collector_queue_utilization:ratio{cluster="$cluster"}', 24),
        panel(8, "日志：ToC", '{business_line="toc", tenant="consumer"}', 24, 12, ds_uid="loki", ds_type="loki"),
        panel(
            9,
            "Exemplar：ToC 延迟 → tempo",
            'http_server_request_duration_seconds_bucket{cluster="$cluster",business_line="toc",tenant="consumer",http_route!="/healthz"}',
            32,
            ds_uid="prometheus",
            exemplar=True,
        ),
    ]
    write_or_check(
        directory / "toc-line.json",
        json.dumps(dashboard("toc-line", "ToC 业务线", toc_panels, [cluster_var()]), indent=2) + "\n",
        check,
    )
    tenant_var = {
        "name": "tenant",
        "label": "Tenant",
        "type": "custom",
        "query": ids.replace("|", ","),
        "includeAll": False,
        "multi": False,
        "current": {"selected": True, "text": "acme", "value": "acme"},
        "options": [
            {"selected": tenant["id"] == "acme", "text": tenant["id"], "value": tenant["id"]}
            for tenant in data["business_lines"]["tob"]["tenants"]
        ],
    }
    tob_panels = [
        panel(1, "基础设施：节点 CPU", 'instance:node_cpu_utilization:ratio{cluster="$cluster"}', 0),
        panel(2, "中间件：Redis 存活", 'redis_up{cluster="$cluster"}', 0, 12),
        panel(3, "应用：ToB 请求速率", 'sum by (service_name, tenant) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="tob",tenant="$tenant",http_route!="/healthz"}[5m]))', 8),
        panel(4, "应用：ToB 5xx 比例", 'sum by (service_name, tenant) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="tob",tenant="$tenant",http_route!="/healthz",http_response_status_code=~"5.."}[5m])) / sum by (service_name, tenant) (rate(http_server_request_duration_seconds_count{cluster="$cluster",business_line="tob",tenant="$tenant",http_route!="/healthz"}[5m]))', 8, 12),
        panel(5, "业务：发票失败比", 'tob:invoices:failure_ratio5m{cluster="$cluster",business_line="tob",tenant="$tenant"}', 16),
        panel(6, "业务：席位占用", 'tob:seats:utilization{cluster="$cluster",business_line="tob",tenant="$tenant"}', 16, 12),
        panel(7, "业务：API 配额", 'tob:api_quota:utilization{cluster="$cluster",business_line="tob",tenant="$tenant"}', 24),
        panel(8, "平台：Collector 队列", 'platform:collector_queue_utilization:ratio{cluster="$cluster"}', 24, 12),
    ]
    y = 32
    pid = 9
    for tenant in data["business_lines"]["tob"]["tenants"]:
        org = tenant["org_id"]
        tob_panels.append(
            panel(
                pid,
                f"Exemplar：{tenant['id']} 延迟 → tempo-{org}",
                'http_server_request_duration_seconds_bucket{cluster="$cluster",business_line="tob",tenant="%s",http_route!="/healthz"}'
                % tenant["id"],
                y,
                ds_uid=f"prometheus-{org}",
                exemplar=True,
            )
        )
        pid += 1
        y += 8
        tob_panels.append(
            panel(
                pid,
                f"日志：{org}",
                '{business_line="tob", tenant="%s"}' % tenant["id"],
                y,
                ds_uid=f"loki-{org}",
                ds_type="loki",
            )
        )
        pid += 1
        tob_panels.append(
            panel(
                pid,
                f"链路指标：{org}",
                'sum by (service, span_name) (rate(traces_spanmetrics_calls_total{cluster="$cluster",tenant="%s",business_line="tob"}[5m]))' % tenant["id"],
                y,
                12,
                ds_uid=f"prometheus-{org}",
            )
        )
        pid += 1
        y += 8
    write_or_check(
        directory / "tob-line.json",
        json.dumps(dashboard("tob-line", "ToB 业务线", tob_panels, [cluster_var(), tenant_var]), indent=2) + "\n",
        check,
    )


def dashboard(uid: str, title: str, panels: list[dict], variables: list[dict]) -> dict:
    return {
        "uid": uid,
        "title": title,
        "schemaVersion": 39,
        "version": 1,
        "refresh": "30s",
        "timezone": "browser",
        "editable": False,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "tags": ["observability", "tenancy", uid],
        "time": {"from": "now-1h", "to": "now"},
        "panels": panels,
        "templating": {"list": variables},
        "annotations": {"list": []},
        "links": [
            {"title": "ToC", "type": "link", "url": "/d/toc-line", "keepTime": True},
            {"title": "ToB", "type": "link", "url": "/d/tob-line", "keepTime": True},
            {"title": "Infrastructure", "type": "link", "url": "/d/infrastructure", "keepTime": True},
            {"title": "Middleware", "type": "link", "url": "/d/middleware", "keepTime": True},
            {"title": "Application", "type": "link", "url": "/d/application", "keepTime": True},
            {"title": "Business", "type": "link", "url": "/d/business", "keepTime": True},
            {"title": "Meta", "type": "link", "url": "/d/meta", "keepTime": True},
        ],
    }


def write_or_check(path: Path, text: str, check: bool) -> None:
    if check:
        if not path.exists() or path.read_text() != text:
            raise SystemExit(f"{path.relative_to(ROOT)} is stale; run make render-tenancy")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def check_mirrors(data: dict) -> None:
    identity = (ROOT / "examples" / "demo-app" / "src" / "demo_app" / "identity.py").read_text()
    if f'TOC_TENANT = "{data["business_lines"]["toc"]["tenant"]}"' not in identity:
        raise SystemExit("identity.py TOC_TENANT drifted from tenancy.yaml")
    expected = ", ".join(f'"{tenant["id"]}"' for tenant in data["business_lines"]["tob"]["tenants"])
    if f"TOB_TENANTS = ({expected})" not in identity:
        raise SystemExit("identity.py TOB_TENANTS drifted from tenancy.yaml")
    alloy_re = "toc|" + "|".join(tenant["org_id"] for tenant in data["business_lines"]["tob"]["tenants"]) + "|platform"
    tenant_re = "consumer|" + "|".join(tenant["id"] for tenant in data["business_lines"]["tob"]["tenants"])
    for rel in ("config/alloy/config.k8s.alloy", "config/alloy/config.workload.alloy"):
        text = (ROOT / rel).read_text()
        if alloy_re not in text or tenant_re not in text:
            raise SystemExit(f"{rel} org/tenant regex drifted from tenancy.yaml ({alloy_re} / {tenant_re})")
    demo = (ROOT / "deploy" / "docker-compose" / "docker-compose.yml").read_text()
    for needle in (
        "BUSINESS_LINE: toc",
        "TENANT_ID: consumer",
        "OTEL_SERVICE_NAME: toc-api",
        "SERVICE_ROLE: api",
        "PYROSCOPE_HTTP_URL: http://pyroscope:4040",
    ):
        if needle not in demo:
            raise SystemExit(f"docker-compose.yml demo-app missing {needle}")
    manifest = (ROOT / "deploy" / "kubernetes" / "base" / "demo-app.yaml").read_text()
    for needle in (
        "value: toc-api",
        "value: toc",
        "value: consumer",
        "value: api",
        "observability.platform/org-id: toc",
        "key: PYROSCOPE_HTTP_URL",
    ):
        if needle not in manifest:
            raise SystemExit(f"demo-app.yaml missing {needle}")


def main() -> None:
    check = "--check" in sys.argv
    data = load_tenancy()
    render_collector(data, check)
    render_datasources(data, check)
    render_rules(data, check)
    render_attach_grafana_alerts(data, check)
    render_compose(data, check)
    render_workloads(data, check)
    render_dashboards(data, check)
    check_mirrors(data)
    print("tenancy render check passed" if check else "rendered tenancy config")


if __name__ == "__main__":
    main()
