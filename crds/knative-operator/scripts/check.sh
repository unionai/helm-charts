#!/usr/bin/env bash
#
# Verify vendored Knative CRDs match a fresh re-pull from upstream at the
# version pinned in ../VERSION. Catches hand edits and upstream-at-same-tag
# content changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

"${SCRIPT_DIR}/sync.sh" "${TMPDIR}" >/dev/null

mismatch=0
shopt -s nullglob
for src in "${CRD_DIR}"/crd-*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${TMPDIR}/${base}" ]]; then
    echo "drift: extra vendored file (not produced by sync.sh): ${base}" >&2
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
    echo "drift: missing vendored file (would be produced by sync.sh): ${base}" >&2
    mismatch=1
  fi
done
shopt -u nullglob

if (( mismatch != 0 )); then
  cat >&2 <<EOF

ERROR: vendored Knative CRDs do not match a fresh sync.sh re-pull.
Run \`make vendor-crds\` and commit the result.
EOF
  exit 1
fi

VERSION="$(cat "${CRD_DIR}/VERSION" | tr -d '[:space:]')"
echo "==> knative-operator CRDs in sync (version ${VERSION}, $(ls "${CRD_DIR}"/crd-*.yaml | wc -l | tr -d ' ') files)"
