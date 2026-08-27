#!/usr/bin/env bash
#
# Re-vendor the dataplane chart's CRDs.
#
# Two responsibilities:
#
#   (a) Pull knative/serving's `serving-crds.yaml` release manifest (12 CRDs:
#       *.serving.knative.dev + *.networking.internal.knative.dev +
#       *.autoscaling.internal.knative.dev + *.caching.internal.knative.dev)
#       at the version pinned in ../VERSION and write one `crd-<name>.yaml`
#       per CRD into charts/dataplane/crds/. The serving CRDs are the
#       upstream-sourced part of the chart.
#
#   (b) Mirror EVERY `charts/dataplane/crds/crd-*.yaml` file (the 12 knative
#       serving CRDs from (a) PLUS any non-knative CRDs in the chart dir,
#       e.g. `crd-flyteworkflows.yaml`) into crds/dataplane/. That mirror
#       dir is installed via SSA by a dedicated ArgoCD `Application` (and is
#       the docs-recommended `kubectl apply --server-side -f crds/dataplane/`
#       target) when the customer opts to manage CRDs out-of-band
#       (`helm install --skip-crds`).
#
# So `charts/dataplane/crds/` is the single source of truth for "what CRDs
# does the dataplane chart need," and `crds/dataplane/` is its byte-identical
# SSA-install mirror.
#
# We deliberately drop the two `*.operator.knative.dev` CRDs (knativeservings,
# knativeeventings) — those live in `crds/knative-operator/` and are only
# installed when the knative-operator subchart is enabled (the non-zero-trust
# legacy path). The dataplane chart in zero-trust mode installs Knative
# Serving directly via the gateway templates without the Operator CR pattern.
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

# (a) Refresh knative serving CRDs in the chart dir. Wipe only the
#     knative-serving subset; non-knative files (crd-flyteworkflows.yaml etc.)
#     stay in place because they're not upstream-sourced from here.
shopt -s nullglob
for f in "${CHART_OUT}"/crd-*.knative.dev.yaml; do rm -f "${f}"; done
shopt -u nullglob

knative_count=0
doc_count="$(yq eval-all '. | document_index' "${TMPDIR}/serving-crds.yaml" | sort -nu | tail -1)"

for i in $(seq 0 "${doc_count}"); do
  kind="$(yq eval-all "select(document_index == ${i}) | .kind // \"\"" "${TMPDIR}/serving-crds.yaml")"
  [[ "${kind}" == "CustomResourceDefinition" ]] || continue

  crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${TMPDIR}/serving-crds.yaml")"
  [[ -n "${crd_name}" && "${crd_name}" != "null" ]] || continue

  doc="$(yq eval-all "select(document_index == ${i})" "${TMPDIR}/serving-crds.yaml")"

  {
    echo "# AUTO-GENERATED — do not edit. Run crds/dataplane/scripts/sync.sh to regenerate."
    echo "# Source: knative/serving release knative-${VERSION}/serving-crds.yaml"
    echo "${doc}"
  } > "${CHART_OUT}/crd-${crd_name}.yaml"

  knative_count=$((knative_count + 1))
done

# (b) Mirror EVERY CRD in the chart dir to the SSA-install mirror dir.
#     This includes both the knative serving CRDs just written above AND any
#     non-knative CRDs the chart ships (e.g. crd-flyteworkflows.yaml).
rm -f "${MIRROR_OUT}"/crd-*.yaml

mirror_count=0
shopt -s nullglob
for src in "${CHART_OUT}"/crd-*.yaml; do
  base="$(basename "${src}")"
  cp "${src}" "${MIRROR_OUT}/${base}"
  mirror_count=$((mirror_count + 1))
done
shopt -u nullglob

echo "==> Wrote ${knative_count} knative serving CRD(s) to chart dir"
echo "==> Mirrored ${mirror_count} CRD(s) (knative serving + non-knative) to mirror dir"
