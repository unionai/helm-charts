#!/usr/bin/env bash
#
# Re-vendor envoy-gateway CRDs into this directory at the version declared by
# charts/controlplane/Chart.yaml's gateway-helm dependency.
#
# gateway-helm ships CRDs in the chart's `crds/` directory split across:
#   - crds/gatewayapi-crds.yaml             (multi-document, 12 standard
#                                            Gateway API CRDs)
#   - crds/generated/gateway.envoyproxy.io_*.yaml  (8 envoy-specific CRDs)
#
# We flatten everything into one directory and split the multi-doc Gateway API
# file into per-CRD files so the SSA-annotation injection treats each CRD
# uniformly and the directory listing matches exactly what ArgoCD applies.
#
# NOTE: this directory vendors BOTH Gateway API standard CRDs and
# envoy-specific CRDs. A customer that already manages Gateway API CRDs from
# another source (e.g. another Gateway API implementation) should opt out of
# this app — see ../../README-vendored-crds.md.
#
# Usage:
#   ./scripts/sync.sh                     # default: writes to parent dir
#   ./scripts/sync.sh /path/to/out/dir    # writes to a custom dir (used by check.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

CP_CHART="${REPO_ROOT}/charts/controlplane/Chart.yaml"
VERSION_FILE="${CRD_DIR}/VERSION"
DEP_NAME="gateway-helm"
OUT_DIR="${1:-${CRD_DIR}}"

command -v yq   >/dev/null || { echo "ERROR: yq not found in PATH" >&2; exit 1; }
command -v helm >/dev/null || { echo "ERROR: helm not found in PATH" >&2; exit 1; }

VERSION="$(yq ".dependencies[] | select(.name == \"${DEP_NAME}\") | .version" "${CP_CHART}")"
if [[ -z "${VERSION}" || "${VERSION}" == "null" ]]; then
  echo "ERROR: could not read '${DEP_NAME}' dep version from ${CP_CHART}" >&2
  exit 1
fi

echo "==> Vendoring envoy-gateway CRDs at version ${VERSION}"
echo "    output dir: ${OUT_DIR}"

mkdir -p "${OUT_DIR}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# gateway-helm is published as an OCI chart on docker.io.
helm pull oci://docker.io/envoyproxy/gateway-helm \
  --version "${VERSION}" \
  --untar --untardir "${TMPDIR}" >/dev/null 2>&1

CRD_SRC="${TMPDIR}/gateway-helm/crds"
if [[ ! -d "${CRD_SRC}" ]]; then
  echo "ERROR: expected CRDs at ${CRD_SRC} for upstream chart ${VERSION}; layout changed?" >&2
  exit 1
fi

# Wipe existing vendored CRDs so removals upstream propagate.
rm -f "${OUT_DIR}"/crd-*.yaml

# Helper: write a single CRD document with the AUTO-GENERATED header.
write_crd() {
  local doc_yaml="$1"
  local dst="$2"
  local source_path="$3"

  {
    echo "# AUTO-GENERATED — do not edit. Run scripts/sync.sh in this directory to regenerate."
    echo "# Source: oci://docker.io/envoyproxy/gateway-helm ${VERSION}"
    echo "#         ${source_path}"
    echo "${doc_yaml}"
  } > "${dst}"
}

count=0

# 1) Multi-doc gatewayapi-crds.yaml — split into one file per CRD.
if [[ -f "${CRD_SRC}/gatewayapi-crds.yaml" ]]; then
  doc_count="$(yq eval-all '. | document_index' "${CRD_SRC}/gatewayapi-crds.yaml" | tail -1)"
  for i in $(seq 0 "${doc_count}"); do
    crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${CRD_SRC}/gatewayapi-crds.yaml")"
    if [[ -z "${crd_name}" || "${crd_name}" == "null" ]]; then continue; fi
    doc_yaml="$(yq eval-all "select(document_index == ${i})" "${CRD_SRC}/gatewayapi-crds.yaml")"
    dst="${OUT_DIR}/crd-${crd_name}.yaml"
    write_crd "${doc_yaml}" "${dst}" "crds/gatewayapi-crds.yaml (document ${i})"
    count=$((count + 1))
  done
fi

# 2) Generated envoy-specific CRDs — one file per CRD already.
for src in "${CRD_SRC}"/generated/*.yaml; do
  [[ -f "${src}" ]] || continue
  crd_name="$(yq '.metadata.name' "${src}")"
  doc_yaml="$(cat "${src}")"
  dst="${OUT_DIR}/crd-${crd_name}.yaml"
  write_crd "${doc_yaml}" "${dst}" "crds/generated/$(basename "${src}")"
  count=$((count + 1))
done

if [[ "${OUT_DIR}" == "${CRD_DIR}" ]]; then
  echo "${VERSION}" > "${VERSION_FILE}"
  echo "==> Updated ${VERSION_FILE#${REPO_ROOT}/} to ${VERSION}"
fi

echo "==> Wrote ${count} CRD manifests"
