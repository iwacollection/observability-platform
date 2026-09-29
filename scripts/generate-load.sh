#!/usr/bin/env bash
# Generate a short burst of demo traffic so metrics, logs, traces, and profiles move.
set -euo pipefail
base="${1:-http://127.0.0.1:8080}"
count="${2:-40}"
for _ in $(seq 1 "$count"); do
  curl -fsS "$base/api/work?burn_ms=30" >/dev/null || true
  curl -fsS "$base/healthz" >/dev/null || true
  curl -sS -o /dev/null "$base/api/error" || true
  curl -fsS "$base/api/slow?seconds=0.05" >/dev/null || true
done
echo "sent $count rounds to $base"
