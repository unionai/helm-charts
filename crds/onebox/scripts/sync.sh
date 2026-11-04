#!/usr/bin/env bash
#
# Copy the Knative Serving CRDs the onebox chart needs (serving.knative) from
# the dataplane chart's crds/, which crds/dataplane/scripts/sync.sh pulls from
# upstream at crds/dataplane/VERSION. onebox runs the same Knative Serving as
# the dataplane's gateway, so the dataplane chart stays the one place Knative
# is bumped: `make vendor-crds` syncs dataplane first, then this.
#
# No mirror dir: for `helm install --skip-crds`, apply the Knative CRDs from
# crds/dataplane/ (kubectl apply --server-side -f 'crds/dataplane/crd-*.knative.dev.yaml').
#
# Usage:
#   ./scripts/sync.sh             # writes charts/onebox/crds/
#   ./scripts/sync.sh OUT_DIR     # custom dir (used by check.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SRC="${REPO_ROOT}/charts/dataplane/crds"
OUT="${1:-${REPO_ROOT}/charts/onebox/crds}"

mkdir -p "${OUT}"
rm -f "${OUT}"/crd-*.yaml

count=0
for src in "${SRC}"/crd-*.knative.dev.yaml; do
  cp "${src}" "${OUT}/"
  count=$((count + 1))
done
(( count > 0 )) || { echo "ERROR: no Knative CRDs in ${SRC}" >&2; exit 1; }
echo "==> Copied ${count} Knative Serving CRD(s) to ${OUT}"
