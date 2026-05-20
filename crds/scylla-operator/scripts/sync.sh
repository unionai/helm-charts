#!/usr/bin/env bash
#
# Re-vendor scylla-operator CRDs into this directory at the version declared by
# charts/controlplane/Chart.yaml's scylla-operator dependency.
#
# scylla-operator ships CRDs in the chart's `crds/` directory (Helm 3
# convention), which means Helm itself does not manage their lifecycle on
# upgrade. We vendor them so a dedicated ArgoCD Application installs them
# with SSA, sidestepping the 256 KiB last-applied-configuration overflow
# the in-CP-app path hits during selfHeal.
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
DEP_NAME="scylla-operator"
OUT_DIR="${1:-${CRD_DIR}}"

command -v yq   >/dev/null || { echo "ERROR: yq not found in PATH" >&2; exit 1; }
command -v helm >/dev/null || { echo "ERROR: helm not found in PATH" >&2; exit 1; }

VERSION="$(yq ".dependencies[] | select(.name == \"${DEP_NAME}\") | .version" "${CP_CHART}")"
if [[ -z "${VERSION}" || "${VERSION}" == "null" ]]; then
  echo "ERROR: could not read '${DEP_NAME}' dep version from ${CP_CHART}" >&2
  exit 1
fi

echo "==> Vendoring ${DEP_NAME} CRDs at version ${VERSION}"
echo "    output dir: ${OUT_DIR}"

mkdir -p "${OUT_DIR}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable >/dev/null 2>&1 \
  || helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable --force-update >/dev/null
helm repo update scylla >/dev/null

helm pull scylla/scylla-operator \
  --version "${VERSION}" \
  --untar --untardir "${TMPDIR}" >/dev/null

CRD_SRC="${TMPDIR}/scylla-operator/crds"
if [[ ! -d "${CRD_SRC}" ]]; then
  echo "ERROR: expected CRDs at ${CRD_SRC} for upstream chart ${VERSION}; layout changed?" >&2
  exit 1
fi

# Wipe existing vendored CRDs so removals upstream propagate.
rm -f "${OUT_DIR}"/00_scylla.scylladb.com_*.yaml

count=0
for src in "${CRD_SRC}"/*.yaml; do
  base="$(basename "${src}")"
  dst="${OUT_DIR}/${base}"

  {
    echo "# AUTO-GENERATED — do not edit. Run scripts/sync.sh in this directory to regenerate."
    echo "# Source: scylla/scylla-operator ${VERSION}"
    echo "#         crds/${base}"
    cat "${src}"
  } > "${dst}"

  count=$((count + 1))
done

if [[ "${OUT_DIR}" == "${CRD_DIR}" ]]; then
  echo "${VERSION}" > "${VERSION_FILE}"
  echo "==> Updated ${VERSION_FILE#${REPO_ROOT}/} to ${VERSION}"
fi

echo "==> Wrote ${count} CRD manifests"
