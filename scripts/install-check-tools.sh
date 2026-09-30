#!/usr/bin/env bash
# Install the CLIs make config-check requires into /tmp/obs-tools/bin.
# Versions follow deploy/images.env. A failed download is a failed install.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="/tmp/obs-tools/bin"
mkdir -p "$dest"
export PATH="${dest}:${PATH}"

pin() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "$root/deploy/images.env")"
  printf '%s' "${line#*=}"
}

version_of() {
  local image
  image="$(pin "$1")"
  printf '%s' "${image##*:}"
}

need() {
  command -v "$1" >/dev/null 2>&1
}

fetch() {
  local url="$1"
  local out="$2"
  curl -fsSL "$url" -o "$out"
}

prom_ver="$(version_of PROMETHEUS_IMAGE)"
prom_ver="${prom_ver#v}"
am_ver="$(version_of ALERTMANAGER_IMAGE)"
am_ver="${am_ver#v}"
alloy_ver="$(version_of ALLOY_IMAGE)"
otel_ver="$(version_of OTELCOL_IMAGE)"
loki_ver="$(version_of LOKI_IMAGE)"
loki_ver="${loki_ver#v}"
kustomize_ver="v5.6.0"
terraform_ver="1.11.4"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! need promtool; then
  fetch "https://github.com/prometheus/prometheus/releases/download/v${prom_ver}/prometheus-${prom_ver}.linux-amd64.tar.gz" "$tmp/prometheus.tar.gz"
  tar -xzf "$tmp/prometheus.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/prometheus-${prom_ver}.linux-amd64/promtool" "$dest/promtool"
fi

if ! need amtool; then
  fetch "https://github.com/prometheus/alertmanager/releases/download/v${am_ver}/alertmanager-${am_ver}.linux-amd64.tar.gz" "$tmp/alertmanager.tar.gz"
  tar -xzf "$tmp/alertmanager.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/alertmanager-${am_ver}.linux-amd64/amtool" "$dest/amtool"
fi

if ! need alloy; then
  fetch "https://github.com/grafana/alloy/releases/download/${alloy_ver}/alloy-linux-amd64.zip" "$tmp/alloy.zip"
  unzip -q -o "$tmp/alloy.zip" -d "$tmp/alloy"
  found="$(find "$tmp/alloy" -type f -name alloy | head -n 1)"
  install -m 0755 "$found" "$dest/alloy"
fi

if ! need otelcol-contrib; then
  fetch "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${otel_ver}/otelcol-contrib_${otel_ver}_linux_amd64.tar.gz" "$tmp/otelcol.tar.gz"
  tar -xzf "$tmp/otelcol.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/otelcol-contrib" "$dest/otelcol-contrib"
fi

if ! need loki; then
  fetch "https://github.com/grafana/loki/releases/download/v${loki_ver}/loki-linux-amd64.zip" "$tmp/loki.zip"
  unzip -q -o "$tmp/loki.zip" -d "$tmp/loki"
  found="$(find "$tmp/loki" -type f -name 'loki-linux-amd64' -o -name loki | head -n 1)"
  install -m 0755 "$found" "$dest/loki"
fi

if ! need kustomize; then
  fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${kustomize_ver}/kustomize_${kustomize_ver}_linux_amd64.tar.gz" "$tmp/kustomize.tar.gz"
  tar -xzf "$tmp/kustomize.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/kustomize" "$dest/kustomize"
fi

if ! need terraform; then
  fetch "https://releases.hashicorp.com/terraform/${terraform_ver}/terraform_${terraform_ver}_linux_amd64.zip" "$tmp/terraform.zip"
  unzip -q -o "$tmp/terraform.zip" -d "$tmp"
  install -m 0755 "$tmp/terraform" "$dest/terraform"
fi

python3 -c 'import yaml' 2>/dev/null || python3 -m pip install --user pyyaml

echo "check tools ready in ${dest}"
