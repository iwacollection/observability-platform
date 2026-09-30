#!/bin/sh
# Copy Grafana alerting files into the live provisioning directory.
# When ALERT_WEBHOOK_URL is set (Compose env, or Secret alert-webhook from
# TF_VAR_alert_webhook_url), critical and warning route to that webhook.
# When it is empty, the committed files are copied unchanged and alerts
# stay in the UI.
set -eu

src="${GRAFANA_ALERTING_SRC:-/etc/grafana/alerting-src}"
dst="${GRAFANA_ALERTING_DST:-/etc/grafana/provisioning/alerting}"
url="${ALERT_WEBHOOK_URL:-}"

mkdir -p "$dst"
cp "$src/rules.yaml" "$dst/rules.yaml"

if [ -z "$url" ]; then
  cp "$src/contact-points.yaml" "$dst/contact-points.yaml"
  cp "$src/policies.yaml" "$dst/policies.yaml"
else
  case "$url" in
    http://*|https://*) ;;
    *)
      echo "ALERT_WEBHOOK_URL must start with http:// or https://" >&2
      exit 1
      ;;
  esac
  rest=$(printf '%s' "$url" | tr -d '[:alnum:]:/?#\[\]@!$&()*+,;=%._~-')
  if [ -n "$rest" ]; then
    echo "ALERT_WEBHOOK_URL contains characters this renderer will not quote" >&2
    exit 1
  fi
  cat >"$dst/contact-points.yaml" <<EOF
apiVersion: 1
contactPoints:
  - orgId: 1
    name: unconfigured
    receivers: []
  - orgId: 1
    name: alert-webhook
    receivers:
      - uid: alert-webhook
        type: webhook
        disableResolveMessage: false
        settings:
          url: "${url}"
          httpMethod: POST
EOF
  cat >"$dst/policies.yaml" <<EOF
apiVersion: 1
policies:
  - orgId: 1
    receiver: unconfigured
    group_by:
      - cluster
      - business_line
      - tenant
      - alertname
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: alert-webhook
        object_matchers:
          - ["severity", "=", "critical"]
        group_by:
          - cluster
          - business_line
          - tenant
          - alertname
      - receiver: alert-webhook
        object_matchers:
          - ["severity", "=", "warning"]
        group_by:
          - cluster
          - business_line
          - tenant
          - alertname
EOF
fi

if [ "${ALERT_RENDER_ONLY:-}" = "1" ]; then
  echo "--- contact-points.yaml"
  cat "$dst/contact-points.yaml"
  echo "--- policies.yaml"
  cat "$dst/policies.yaml"
  exit 0
fi

exec /run.sh
