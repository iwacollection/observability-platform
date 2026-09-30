#!/usr/bin/env bash
# Format-check and validate the example Terraform stack.
# Does not contact a Kubernetes API and does not read a kubeconfig.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="$root/deploy/terraform/stacks/platform"
export PATH="/tmp/obs-tools/bin:${PATH}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL terraform not found" >&2
  exit 1
fi

echo "== terraform fmt"
terraform fmt -check -recursive -diff "$root/deploy/terraform"

echo "== terraform coverage"
python3 "$root/deploy/terraform/scripts/check-coverage.py"

echo "== terraform init"
terraform -chdir="$stack" init -backend=false -input=false

echo "== terraform validate"
terraform -chdir="$stack" validate
