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

write_ingest_secret() {
  if [[ "$ingest_secret_mode" != "script" || -z "${INGEST_TOKEN:-}" ]]; then
    return 0
  fi
  "${kc[@]}" -n observability create secret generic ingest-auth \
    --from-literal=token="$INGEST_TOKEN" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
}

if [[ "$action" == "delete" ]]; then
  # Secret ingest-auth on a workload cluster is not in the agent kustomization.
  # Delete it before the namespace. Prod central's copy is a Terraform resource.
  if [[ "${DELETE_INGEST_SECRET:-}" == "true" ]]; then
    if "${kc[@]}" get namespace observability >/dev/null 2>&1; then
      "${kc[@]}" -n observability delete secret ingest-auth --ignore-not-found
    fi
  fi
  "${kc[@]}" delete -f "$manifest" --ignore-not-found
  if [[ "${DELETE_ENDPOINTS:-}" == "true" ]]; then
    "${kc[@]}" -n observability delete configmap observability-endpoints --ignore-not-found
  fi
  exit 0
fi

if [[ "$action" != "apply" ]]; then
  echo "unknown action: $action" >&2
  exit 1
fi

if [[ -n "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
  "${kc[@]}" create namespace observability --dry-run=client -o yaml | "${kc[@]}" apply -f -
  "${kc[@]}" -n observability create configmap observability-endpoints \
    --from-literal=CLUSTER_NAME="$ENDPOINTS_CLUSTER_NAME" \
    --from-literal=PROMETHEUS_REMOTE_WRITE_URL="$ENDPOINTS_PROMETHEUS_REMOTE_WRITE_URL" \
    --from-literal=LOKI_PUSH_URL="$ENDPOINTS_LOKI_PUSH_URL" \
    --from-literal=LOKI_OTLP_ENDPOINT="$ENDPOINTS_LOKI_OTLP_ENDPOINT" \
    --from-literal=TEMPO_OTLP_ENDPOINT="$ENDPOINTS_TEMPO_OTLP_ENDPOINT" \
    --from-literal=PYROSCOPE_OTLP_ENDPOINT="$ENDPOINTS_PYROSCOPE_OTLP_ENDPOINT" \
    --from-literal=PYROSCOPE_HTTP_URL="$ENDPOINTS_PYROSCOPE_HTTP_URL" \
    --dry-run=client -o yaml | "${kc[@]}" apply -f -
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

if [[ -n "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
  "${kc[@]}" -n observability rollout restart daemonset/alloy deployment/otel-collector
  "${kc[@]}" -n observability rollout status daemonset/alloy --timeout=180s
  "${kc[@]}" -n observability rollout status deployment/otel-collector --timeout=180s
fi
