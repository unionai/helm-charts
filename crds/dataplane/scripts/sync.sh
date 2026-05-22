#!/usr/bin/env bash
#
# Re-vendor Knative Serving CRDs at the version pinned in ../VERSION.
#
# Pulls knative/serving's `serving-crds.yaml` release manifest (12 CRDs:
# *.serving.knative.dev + *.networking.internal.knative.dev +
# *.autoscaling.internal.knative.dev + *.caching.internal.knative.dev) and
# writes one `crd-<name>.yaml` per CRD to BOTH:
#
#   1. charts/dataplane/crds/  — the Helm `crds/` directory. Helm 3 installs
#                                these automatically on `helm install` unless
#                                the user passes `--skip-crds`. The chart's
#                                source of truth.
#   2. crds/dataplane/         — a byte-identical mirror, used by a dedicated
#                                ArgoCD `Application` (and the docs-recommended
#                                `kubectl apply --server-side -f crds/dataplane/`
#                                path) when the customer opts to manage CRDs
#                                out-of-band (`helm install --skip-crds`).
#
# Non-Knative CRDs in the chart dir (e.g. `crd-flyteworkflows.yaml`) are
# preserved — sync.sh only refreshes files matching `crd-*.knative.dev.yaml`.
#
# We deliberately drop the two `*.operator.knative.dev` CRDs (knativeservings,
# knativeeventings) that the previous knative-operator vendoring included:
# the dataplane chart now installs Knative Serving directly via the gateway
# templates rather than via the Knative Operator CR pattern, so the operator
# CRDs are no longer needed.
#
# Bumping Knative:
#   1. Edit ./VERSION (e.g. v1.17.0).
#   2. make vendor-crds
#   3. Review diff, make check-vendored-crds, commit.
#
# Usage:
#   ./scripts/sync.sh                                # writes to default chart + mirror dirs
#   ./scripts/sync.sh CHART_OUT_DIR MIRROR_OUT_DIR   # custom dirs (used by check.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

VERSION_FILE="${CRD_DIR}/VERSION"

CHART_OUT="${1:-${REPO_ROOT}/charts/dataplane/crds}"
MIRROR_OUT="${2:-${CRD_DIR}}"

command -v yq   >/dev/null || { echo "ERROR: yq not found in PATH"   >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found in PATH" >&2; exit 1; }

VERSION="$(cat "${VERSION_FILE}" | tr -d '[:space:]')"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: ${VERSION_FILE} is empty; set e.g. v1.16.0" >&2
  exit 1
fi

echo "==> Vendoring Knative Serving CRDs at version ${VERSION}"
echo "    chart dir : ${CHART_OUT}"
echo "    mirror dir: ${MIRROR_OUT}"

mkdir -p "${CHART_OUT}" "${MIRROR_OUT}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

SRC_URL="https://github.com/knative/serving/releases/download/knative-${VERSION}/serving-crds.yaml"
curl -fsSL "${SRC_URL}" > "${TMPDIR}/serving-crds.yaml"

# Wipe Knative CRDs from chart dir; preserve non-Knative files (e.g. crd-flyteworkflows.yaml).
shopt -s nullglob
for f in "${CHART_OUT}"/crd-*.knative.dev.yaml; do rm -f "${f}"; done
# Mirror dir holds only Knative CRDs today, so wipe all crd-*.yaml. If the
# dataplane chart's crds/ dir ever ships more non-Knative CRDs that we want
# mirrored here, extend the mirror step below to copy them through as well.
for f in "${MIRROR_OUT}"/crd-*.yaml; do rm -f "${f}"; done
shopt -u nullglob

count=0
doc_count="$(yq eval-all '. | document_index' "${TMPDIR}/serving-crds.yaml" | sort -nu | tail -1)"

for i in $(seq 0 "${doc_count}"); do
  kind="$(yq eval-all "select(document_index == ${i}) | .kind // \"\"" "${TMPDIR}/serving-crds.yaml")"
  [[ "${kind}" == "CustomResourceDefinition" ]] || continue

  crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${TMPDIR}/serving-crds.yaml")"
  [[ -n "${crd_name}" && "${crd_name}" != "null" ]] || continue

  doc="$(yq eval-all "select(document_index == ${i})" "${TMPDIR}/serving-crds.yaml")"

  header_block="# AUTO-GENERATED — do not edit. Run crds/dataplane/scripts/sync.sh to regenerate.
# Source: knative/serving release knative-${VERSION}/serving-crds.yaml"

  for dst_dir in "${CHART_OUT}" "${MIRROR_OUT}"; do
    {
      echo "${header_block}"
      echo "${doc}"
    } > "${dst_dir}/crd-${crd_name}.yaml"
  done

  count=$((count + 1))
done

echo "==> Wrote ${count} CRD manifest(s) to each of chart + mirror"
