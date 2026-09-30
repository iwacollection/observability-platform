#!/usr/bin/env bash
# Apply or delete a kustomize tree with an explicit kubeconfig.
# Terraform local-exec is the only caller. Do not run this by hand to install
# the stack.
#
# Workload agents also refresh ConfigMap observability-endpoints from the
# environment. INGEST_SECRET_MODE=script writes Secret ingest-auth when
# INGEST_TOKEN is set. INGEST_SECRET_MODE=provider leaves that Secret to
# kubernetes_secret_v1 (prod central). The token is not stored in this file.
set -euo pipefail

action="${1:?usage: kubectl-apply.sh apply|delete}"
: "${KUBECONFIG:?KUBECONFIG is required}"
: "${KUSTOMIZE_PATH:?KUSTOMIZE_PATH is required}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required to apply the stack" >&2
  exit 1
fi
if ! command -v kustomize >/dev/null 2>&1; then
  echo "kustomize is required to build the stack" >&2
  exit 1
fi

kc=(kubectl --kubeconfig "$KUBECONFIG")
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  kc+=(--context "$KUBE_CONTEXT")
fi

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
kustomize build --load-restrictor LoadRestrictionsNone "$KUSTOMIZE_PATH" >"$manifest"

ingest_secret_mode="${INGEST_SECRET_MODE:-script}"
case "$ingest_secret_mode" in
  script | provider) ;;
  *)
    echo "unknown INGEST_SECRET_MODE: $ingest_secret_mode" >&2
    exit 1
    ;;
esac

# Secret alert-webhook holds the paging URL. The value comes from
# ALERT_WEBHOOK_URL, which Terraform sets from TF_VAR_alert_webhook_url.
# Empty deletes the Secret. The Deployment reads it with optional: true,
# and the entrypoint then leaves critical and warning in the UI.
write_alert_webhook() {
  if [[ "${MANAGE_ALERT_WEBHOOK:-}" != "true" ]]; then
    return 0
  fi
  "${kc[@]}" create namespace observability --dry-run=client -o yaml | "${kc[@]}" apply -f -
  if [[ -z "${ALERT_WEBHOOK_URL:-}" ]]; then
    "${kc[@]}" -n observability delete secret alert-webhook --ignore-not-found
    return 0
  fi
  case "$ALERT_WEBHOOK_URL" in
    http://*|https://*) ;;
    *)
      echo "ALERT_WEBHOOK_URL must start with http:// or https://" >&2
      exit 1
      ;;
  esac
  rest=$(printf '%s' "$ALERT_WEBHOOK_URL" | tr -d '[:alnum:]:/?#\[\]@!$&()*+,;=%._~-')
  if [ -n "$rest" ]; then
    echo "ALERT_WEBHOOK_URL contains characters that are not written into the Secret" >&2
    exit 1
  fi
  "${kc[@]}" -n observability create secret generic alert-webhook \
    --from-literal=url="$ALERT_WEBHOOK_URL" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
}

write_cluster_binding() {
  if [[ -z "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
    return 0
  fi
  "${kc[@]}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: observability-cluster-binding
  namespace: observability
  labels:
    app.kubernetes.io/part-of: observability-platform
    observability.platform/cluster: ${ENDPOINTS_CLUSTER_NAME}
data:
  cluster: ${ENDPOINTS_CLUSTER_NAME}
  managed_by: terraform-kubectl
EOF
}

write_ingest_secret() {
  if [[ "$ingest_secret_mode" != "script" || -z "${INGEST_TOKEN:-}" ]]; then
    return 0
  fi
  "${kc[@]}" -n observability create secret generic ingest-auth \
    --from-literal=token="$INGEST_TOKEN" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
}

# PEM comes from the environment only. Do not echo it and do not write it
# into the kustomize tree. An empty value removes a previously applied CA.
write_exporter_tls_ca() {
  if [[ ! -v EXPORTER_TLS_CA_PEM ]]; then
    return 0
  fi
  if [[ -z "${EXPORTER_TLS_CA_PEM}" ]]; then
    if "${kc[@]}" get namespace observability >/dev/null 2>&1; then
      "${kc[@]}" -n observability delete secret otel-exporter-tls-ca --ignore-not-found
    fi
    return 0
  fi
  "${kc[@]}" -n observability create secret generic otel-exporter-tls-ca \
    --from-literal=ca.pem="$EXPORTER_TLS_CA_PEM" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
}

apply_or_delete_workloads() {
  local mode="${1:?apply or delete}"
  if [[ -z "${WORKLOADS_KUSTOMIZE_PATH:-}" ]]; then
    return 0
  fi
  local workloads
  workloads="$(mktemp)"
  kustomize build --load-restrictor LoadRestrictionsNone "$WORKLOADS_KUSTOMIZE_PATH" >"$workloads"
  if [[ "$mode" == "apply" ]]; then
    "${kc[@]}" apply -f "$workloads"
  else
    "${kc[@]}" delete -f "$workloads" --ignore-not-found
  fi
  rm -f "$workloads"
}

if [[ "$action" == "delete" ]]; then
  # Secret ingest-auth on a workload cluster is not in the agent kustomization.
  # Delete it before the namespace. Prod central's copy is a Terraform resource.
  if [[ "${DELETE_INGEST_SECRET:-}" == "true" ]]; then
    if "${kc[@]}" get namespace observability >/dev/null 2>&1; then
      "${kc[@]}" -n observability delete secret ingest-auth --ignore-not-found
      "${kc[@]}" -n observability delete secret otel-exporter-tls-ca --ignore-not-found
    fi
  fi
  # Demo workloads are not in the agent manifest. Delete them before the
  # namespace so a later apply with the flag off does not leave them behind
  # on destroy. Missing objects are ignored.
  apply_or_delete_workloads delete
  "${kc[@]}" delete -f "$manifest" --ignore-not-found
  if [[ "${DELETE_ENDPOINTS:-}" == "true" ]]; then
    "${kc[@]}" -n observability delete configmap observability-endpoints --ignore-not-found
    "${kc[@]}" -n observability delete configmap observability-cluster-binding --ignore-not-found
  fi
  if [[ "${MANAGE_ALERT_WEBHOOK:-}" == "true" ]]; then
    if "${kc[@]}" get namespace observability >/dev/null 2>&1; then
      "${kc[@]}" -n observability delete secret alert-webhook --ignore-not-found
    fi
  fi
  exit 0
fi

if [[ "$action" != "apply" ]]; then
  echo "unknown action: $action" >&2
  exit 1
fi

if [[ -n "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
  "${kc[@]}" create namespace observability --dry-run=client -o yaml | "${kc[@]}" apply -f -
  # TENANT, BUSINESS_LINE, and ORG_ID may be empty. Empty does not overwrite
  # application labels. The attach-existing stack sets all three.
  "${kc[@]}" -n observability create configmap observability-endpoints \
    --from-literal=CLUSTER_NAME="$ENDPOINTS_CLUSTER_NAME" \
    --from-literal=PROMETHEUS_REMOTE_WRITE_URL="$ENDPOINTS_PROMETHEUS_REMOTE_WRITE_URL" \
    --from-literal=LOKI_PUSH_URL="$ENDPOINTS_LOKI_PUSH_URL" \
    --from-literal=LOKI_OTLP_ENDPOINT="$ENDPOINTS_LOKI_OTLP_ENDPOINT" \
    --from-literal=TEMPO_OTLP_ENDPOINT="$ENDPOINTS_TEMPO_OTLP_ENDPOINT" \
    --from-literal=PYROSCOPE_OTLP_ENDPOINT="$ENDPOINTS_PYROSCOPE_OTLP_ENDPOINT" \
    --from-literal=PYROSCOPE_HTTP_URL="$ENDPOINTS_PYROSCOPE_HTTP_URL" \
    --from-literal=TENANT="${ENDPOINTS_TENANT:-}" \
    --from-literal=BUSINESS_LINE="${ENDPOINTS_BUSINESS_LINE:-}" \
    --from-literal=ORG_ID="${ENDPOINTS_ORG_ID:-}" \
    --from-literal=OTEL_EXPORTER_TLS_INSECURE="${ENDPOINTS_EXPORTER_TLS_INSECURE:-false}" \
    --from-literal=OTEL_EXPORTER_TLS_CA_FILE="${ENDPOINTS_EXPORTER_TLS_CA_FILE:-}" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
  write_cluster_binding
fi

write_alert_webhook

if [[ "${MANAGE_ALERT_WEBHOOK:-}" == "true" ]]; then
  python3 - "$manifest" "${ALERT_WEBHOOK_URL:-}" <<'PY'
import hashlib
import sys
from pathlib import Path

path, url = sys.argv[1], sys.argv[2]
text = Path(path).read_text()
marker = "observability.platform/alert-paging: unconfigured"
if marker not in text:
    raise SystemExit("alert-paging annotation missing from the rendered stack")
value = "unconfigured"
if url:
    value = hashlib.sha256(url.encode()).hexdigest()[:16]
Path(path).write_text(text.replace(marker, f"observability.platform/alert-paging: {value}"))
PY
fi

if [[ -n "${WORKLOAD_COLLECTOR_REPLICAS:-}" ]]; then
  python3 - "$manifest" "$WORKLOAD_COLLECTOR_REPLICAS" <<'PY'
import re
import sys
from pathlib import Path

path, raw = sys.argv[1], sys.argv[2]
count = int(raw)
if count < 2:
    raise SystemExit("WORKLOAD_COLLECTOR_REPLICAS must be >= 2")
text = Path(path).read_text()
docs = text.split("---\n")
found = False
out = []
for doc in docs:
    if re.search(r"^kind: Deployment\n", doc, re.M) and re.search(r"^  name: otel-collector\n", doc, re.M):
        doc, n = re.subn(r"^  replicas: \d+\n", f"  replicas: {count}\n", doc, count=1, flags=re.M)
        if n != 1:
            raise SystemExit("could not set otel-collector replicas")
        found = True
    out.append(doc)
if not found:
    raise SystemExit("workload manifest has no otel-collector Deployment")
Path(path).write_text("---\n".join(out))
PY
fi

"${kc[@]}" apply -f "$manifest"

# After the overlay apply, so a dev placeholder does not clobber TF_VAR_ingest_token.
# Provider mode (prod central) does not create the Secret here.
write_ingest_secret
write_exporter_tls_ca

# Unset leaves central workloads alone. "true" installs the generated demo
# businesses. "false" removes them from this workload cluster.
if [[ "${INSTALL_DEMO_WORKLOADS:-}" == "true" ]]; then
  apply_or_delete_workloads apply
elif [[ "${INSTALL_DEMO_WORKLOADS:-}" == "false" ]]; then
  apply_or_delete_workloads delete
fi

if [[ -n "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
  "${kc[@]}" -n observability rollout restart daemonset/alloy deployment/otel-collector
  "${kc[@]}" -n observability rollout status daemonset/alloy --timeout=180s
  "${kc[@]}" -n observability rollout status deployment/otel-collector --timeout=180s
fi
