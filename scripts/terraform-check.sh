#!/usr/bin/env bash
# Format-check and validate the platform stack and the attach-existing stack.
# Does not contact a Kubernetes API and does not read a kubeconfig.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/tmp/obs-tools/bin:${PATH}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL terraform not found" >&2
  exit 1
fi

echo "== terraform fmt"
terraform fmt -check -recursive -diff "$root/deploy/terraform"

echo "== terraform coverage"
python3 "$root/deploy/terraform/scripts/check-coverage.py"

for stack in \
  "$root/deploy/terraform/stacks/platform" \
  "$root/deploy/terraform/stacks/attach-existing"
do
  name="$(basename "$stack")"
  echo "== terraform init $name"
  terraform -chdir="$stack" init -backend=false -input=false
  echo "== terraform validate $name"
  terraform -chdir="$stack" validate
done
