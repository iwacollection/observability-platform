#!/bin/sh
# Render the ingest gateway from the pinned nginx image. The token is read
# from INGEST_TOKEN at start. It is not baked into the template.
set -eu

: "${INGEST_TOKEN:?INGEST_TOKEN is required}"
: "${GATEWAY_MODE:?GATEWAY_MODE is required}"
: "${HTTP_LISTEN:?HTTP_LISTEN is required}"
: "${HTTP_UPSTREAM:?HTTP_UPSTREAM is required}"

case "$GATEWAY_MODE" in
  http)
    src=/etc/ingest-gateway/http.conf.template
    ;;
  tempo)
    src=/etc/ingest-gateway/tempo.conf.template
    : "${GRPC_LISTEN:?GRPC_LISTEN is required}"
    : "${GRPC_UPSTREAM:?GRPC_UPSTREAM is required}"
    : "${OTLP_HTTP_LISTEN:?OTLP_HTTP_LISTEN is required}"
    : "${OTLP_HTTP_UPSTREAM:?OTLP_HTTP_UPSTREAM is required}"
    ;;
  pyroscope)
    src=/etc/ingest-gateway/pyroscope.conf.template
    ;;
  *)
    echo "unknown GATEWAY_MODE=$GATEWAY_MODE" >&2
    exit 1
    ;;
esac

# Only these placeholders are substituted. Nginx variables ($host, $ingest_ok)
# stay in the file.
envsubst '${INGEST_TOKEN} ${HTTP_LISTEN} ${HTTP_UPSTREAM} ${GRPC_LISTEN} ${GRPC_UPSTREAM} ${OTLP_HTTP_LISTEN} ${OTLP_HTTP_UPSTREAM}' \
  <"$src" >/tmp/nginx.conf

exec nginx -c /tmp/nginx.conf -g 'daemon off;'
