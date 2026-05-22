#!/usr/bin/env bash
#
# Verify that vendored envoy-gateway CRDs are consistent across:
#   - charts/controlplane/Chart.yaml          gateway-helm dep version (source of truth)
#   - crds/envoy-gateway/VERSION              (must match CP dep)
#   - crds/envoy-gateway/crd-*.yaml           bytes equal sync.sh re-run
#
# Note: envoy-gateway is only a CP dependency in the current chart layout, so
# we do not compare DP Chart.yaml here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

CP_CHART="${REPO_ROOT}/charts/controlplane/Chart.yaml"
VERSION_FILE="${CRD_DIR}/VERSION"
DEP_NAME="gateway-helm"

CP_VER="$(yq ".dependencies[] | select(.name == \"${DEP_NAME}\") | .version" "${CP_CHART}")"
VENDORED_VER="$(cat "${VERSION_FILE}" | tr -d '[:space:]')"

if [[ "${CP_VER}" != "${VENDORED_VER}" ]]; then
  cat >&2 <<EOF
ERROR: vendored CRDs VERSION does not match controlplane dep version.
  charts/controlplane/Chart.yaml ${DEP_NAME} dep: ${CP_VER}
  crds/envoy-gateway/VERSION:                    ${VENDORED_VER}
Run \`make vendor-crds\` to refresh.
EOF
  exit 1
fi

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

ERROR: vendored CRD YAML does not match \`sync.sh\` output for ${DEP_NAME} ${CP_VER}.
Run \`make vendor-crds\` and commit the result.
EOF
  exit 1
fi

echo "==> envoy-gateway CRDs in sync (version ${CP_VER}, $(ls "${CRD_DIR}"/crd-*.yaml 2>/dev/null | wc -l | tr -d ' ') files)"
