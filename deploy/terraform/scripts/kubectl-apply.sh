#!/usr/bin/env bash
# Apply or delete a kustomize tree with an explicit kubeconfig.
# Workload agents also refresh the observability-endpoints ConfigMap from
# the environment. Tokens are not read from this script.
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

if [[ "$action" == "delete" ]]; then
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

"${kc[@]}" apply -f "$manifest"

if [[ -n "${ENDPOINTS_CLUSTER_NAME:-}" ]]; then
  "${kc[@]}" -n observability rollout restart daemonset/alloy deployment/otel-collector
  "${kc[@]}" -n observability rollout status daemonset/alloy --timeout=180s
  "${kc[@]}" -n observability rollout status deployment/otel-collector --timeout=180s
fi
