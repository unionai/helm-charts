#!/usr/bin/env bash
#
# Re-vendor the FlyteWorkflow CRD into this directory by copying it from the
# Helm-managed source of truth at charts/dataplane/crds/. Helm's `crds/`
# convention installs that file automatically on `helm install` (no template
# rendering); we keep a byte-identical mirror here so a dedicated ArgoCD
# Application can install it with SSA when the customer opts out of Helm-
# managed CRDs (`helm install --skip-crds`).
#
# This is the same shape as the other crds/<name>/scripts/sync.sh scripts,
# but with no upstream chart to pull from — the "upstream" is just the
# chart-dir file in this repo. There is no VERSION file for the same reason.
#
# Usage:
#   ./scripts/sync.sh                     # default: writes to parent dir
#   ./scripts/sync.sh /path/to/out/dir    # writes to a custom dir (used by check.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

SRC_DIR="${REPO_ROOT}/charts/dataplane/crds"
OUT_DIR="${1:-${CRD_DIR}}"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "ERROR: expected source CRDs at ${SRC_DIR}; was the chart's crds/ dir moved?" >&2
  exit 1
fi

echo "==> Mirroring flyte-v1 CRDs from ${SRC_DIR#${REPO_ROOT}/}"
echo "    output dir: ${OUT_DIR}"

mkdir -p "${OUT_DIR}"

# Wipe existing vendored Flyte CRDs so removals at the source propagate.
# We only own the Flyte-domain CRDs in the chart dir; siblings (e.g. the
# vendored Knative serving CRDs `crd-*.knative.dev.yaml`) are mirrored by
# their own crds/<name>/ dir and must not be touched here.
rm -f "${OUT_DIR}"/crd-flyte*.yaml

count=0
shopt -s nullglob
for src in "${SRC_DIR}"/crd-flyte*.yaml; do
  base="$(basename "${src}")"
  dst="${OUT_DIR}/${base}"

  {
    echo "# AUTO-GENERATED — do not edit. Run scripts/sync.sh in this directory to regenerate."
    echo "# Source: charts/dataplane/crds/${base}"
    cat "${src}"
  } > "${dst}"

  count=$((count + 1))
done
shopt -u nullglob

if (( count == 0 )); then
  echo "ERROR: no crd-*.yaml files found at ${SRC_DIR}" >&2
  exit 1
fi

echo "==> Wrote ${count} CRD manifest(s)"
