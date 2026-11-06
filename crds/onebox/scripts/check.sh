#!/usr/bin/env bash
#
# Verify charts/onebox/crds/ matches a fresh sync.sh copy of the dataplane
# chart's Knative Serving CRDs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/onebox/crds"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

"${SCRIPT_DIR}/sync.sh" "${TMPDIR}" >/dev/null

if ! diff -ru "${CHART_DIR}" "${TMPDIR}" >&2; then
  echo "ERROR: charts/onebox/crds/ differs from the dataplane chart's Knative CRDs. Run \`make vendor-crds\` and commit the result." >&2
  exit 1
fi
echo "==> onebox CRDs in sync ($(ls "${CHART_DIR}"/crd-*.yaml | wc -l | tr -d ' ') Knative Serving CRDs)"
