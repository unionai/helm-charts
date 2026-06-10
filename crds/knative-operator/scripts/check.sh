#!/usr/bin/env bash
#
# Verify the vendored Knative CRDs AND the chart-dir copy at
# charts/knative-operator/crds/ both match a fresh re-pull from upstream at
# the version pinned in ../VERSION. Catches hand edits, upstream-at-same-tag
# content changes, and drift between the two on-disk copies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"
CHART_CRD_DIR="${REPO_ROOT}/charts/knative-operator/crds"

TMPDIR="$(mktemp -d)"
TMP_VENDOR_DIR="${TMPDIR}/vendor"
TMP_CHART_DIR="${TMPDIR}/chart"
mkdir -p "${TMP_VENDOR_DIR}" "${TMP_CHART_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

"${SCRIPT_DIR}/sync.sh" "${TMP_VENDOR_DIR}" "${TMP_CHART_DIR}" >/dev/null

mismatch=0

diff_dir() {
  local label="$1"
  local on_disk="$2"
  local fresh="$3"

  shopt -s nullglob
  for src in "${on_disk}"/crd-*.yaml; do
    base="$(basename "${src}")"
    if [[ ! -f "${fresh}/${base}" ]]; then
      echo "drift (${label}): extra on-disk file (not produced by sync.sh): ${base}" >&2
      mismatch=1
      continue
    fi
    if ! diff -u "${src}" "${fresh}/${base}" >&2; then
      mismatch=1
    fi
  done
  for src in "${fresh}"/crd-*.yaml; do
    base="$(basename "${src}")"
    if [[ ! -f "${on_disk}/${base}" ]]; then
      echo "drift (${label}): missing on-disk file (would be produced by sync.sh): ${base}" >&2
      mismatch=1
    fi
  done
  shopt -u nullglob
}

diff_dir "vendored mirror" "${CRD_DIR}"       "${TMP_VENDOR_DIR}"
diff_dir "chart crds"      "${CHART_CRD_DIR}" "${TMP_CHART_DIR}"

if (( mismatch != 0 )); then
  cat >&2 <<EOF

ERROR: vendored Knative CRDs do not match a fresh sync.sh re-pull.
Run \`make vendor-crds\` and commit the result.
EOF
  exit 1
fi

VERSION="$(cat "${CRD_DIR}/VERSION" | tr -d '[:space:]')"
mirror_count="$(ls "${CRD_DIR}"/crd-*.yaml 2>/dev/null | wc -l | tr -d ' ')"
chart_count="$(ls "${CHART_CRD_DIR}"/crd-*.yaml 2>/dev/null | wc -l | tr -d ' ')"
echo "==> knative-operator CRDs in sync (version ${VERSION}, mirror=${mirror_count} files, chart=${chart_count} files)"
