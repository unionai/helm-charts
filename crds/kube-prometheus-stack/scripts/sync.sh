#!/usr/bin/env bash
#
# Re-vendor kube-prometheus-stack CRDs into this directory at the version
# declared by charts/controlplane/Chart.yaml's kube-prometheus-stack
# dependency.
#
# Source of truth for the version is charts/controlplane/Chart.yaml. This
# script reads it, pulls the matching upstream chart, writes CRD manifests
# (with the ArgoCD ServerSideApply sync-option annotation injected) into the
# parent directory, and updates VERSION to match.
#
# Drift between any of these is caught by scripts/check.sh, wired into
# `make check-vendored-crds` and `make test`.
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
DEP_NAME="kube-prometheus-stack"
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

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 \
  || helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update prometheus-community >/dev/null

helm pull prometheus-community/kube-prometheus-stack \
  --version "${VERSION}" \
  --untar --untardir "${TMPDIR}" >/dev/null

# In KPS >=45 the CRDs live in a `crds` subchart, inside its own `crds/` dir.
CRD_SRC="${TMPDIR}/kube-prometheus-stack/charts/crds/crds"
if [[ ! -d "${CRD_SRC}" ]]; then
  echo "ERROR: expected CRDs at ${CRD_SRC} for upstream chart ${VERSION}; layout changed?" >&2
  exit 1
fi

# Wipe existing crd-*.yaml so removals upstream propagate. Leave other
# files (README, VERSION, scripts/) in place.
rm -f "${OUT_DIR}"/crd-*.yaml

count=0
for src in "${CRD_SRC}"/crd-*.yaml; do
  base="$(basename "${src}")"
  dst="${OUT_DIR}/${base}"

  {
    echo "# AUTO-GENERATED — do not edit. Run scripts/sync.sh in this directory to regenerate."
    echo "# Source: prometheus-community/kube-prometheus-stack ${VERSION}"
    echo "#         charts/crds/crds/${base}"
    cat "${src}"
  } > "${dst}"

  count=$((count + 1))
done

# Only update VERSION when sync.sh wrote to the canonical dir. When called
# with an output dir (by check.sh), leave VERSION alone.
if [[ "${OUT_DIR}" == "${CRD_DIR}" ]]; then
  echo "${VERSION}" > "${VERSION_FILE}"
  echo "==> Updated ${VERSION_FILE#${REPO_ROOT}/} to ${VERSION}"
fi

echo "==> Wrote ${count} CRD manifests"
