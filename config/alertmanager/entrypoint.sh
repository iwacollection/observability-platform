#!/bin/sh
# Render the Alertmanager config, then start Alertmanager.
# ALERT_WEBHOOK_URL is the runtime switch. Terraform sets it from
# TF_VAR_alert_webhook_url by creating Secret alert-webhook. Compose reads
# the same variable. Empty means the committed file is used unchanged:
# critical and warning stay in the UI.
set -eu

src="${ALERTMANAGER_CONFIG_SRC:-/etc/alertmanager/alertmanager.yml}"
dst="${ALERTMANAGER_CONFIG_DST:-/tmp/alertmanager.yml}"
url="${ALERT_WEBHOOK_URL:-}"

cp "$src" "$dst"

if [ -n "$url" ]; then
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
  tmp="${dst}.tmp"
  awk -v url="$url" '
    $0 == "  - name: critical" || $0 == "  - name: warning" {
      print
      print "    webhook_configs:"
      print "      - url: \"" url "\""
      print "        send_resolved: true"
      next
    }
    { print }
  ' "$dst" >"$tmp"
  mv "$tmp" "$dst"
fi

if [ "${ALERT_RENDER_ONLY:-}" = "1" ]; then
  cat "$dst"
  exit 0
fi

exec /bin/alertmanager \
  --config.file="$dst" \
  --storage.path="${ALERTMANAGER_STORAGE_PATH:-/alertmanager}" \
  --web.listen-address=0.0.0.0:9093
