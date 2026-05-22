#!/usr/bin/env bash
#
# Verify the mirrored FlyteWorkflow CRD in this directory is byte-identical
# to a fresh `sync.sh` re-run against the chart-dir source of truth at
# charts/dataplane/crds/. Hand-editing either copy (or editing the chart
# source without re-running `make vendor-crds`) fails the check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

"${SCRIPT_DIR}/sync.sh" "${TMPDIR}" >/dev/null

mismatch=0
shopt -s nullglob
for src in "${CRD_DIR}"/crd-*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${TMPDIR}/${base}" ]]; then
    echo "drift: extra mirrored file (not produced by sync.sh): ${base}" >&2
    mismatch=1
    continue
  fi
  if ! diff -u "${src}" "${TMPDIR}/${base}" >&2; then
    mismatch=1
  fi
done
for src in "${TMPDIR}"/crd-*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${CRD_DIR}/${base}" ]]; then
    echo "drift: missing mirrored file (would be produced by sync.sh): ${base}" >&2
    mismatch=1
  fi
done
shopt -u nullglob

if (( mismatch != 0 )); then
  cat >&2 <<EOF

ERROR: vendored CRD YAML in crds/flyte-v1/ does not match the chart-dir
source at charts/dataplane/crds/. Edit the chart-dir file (source of truth)
then run \`make vendor-crds\` and commit the result.
EOF
  exit 1
fi

echo "==> flyte-v1 CRDs in sync ($(ls "${CRD_DIR}"/crd-*.yaml 2>/dev/null | wc -l | tr -d ' ') file(s))"
