#!/usr/bin/env bash
#
# Re-vendor the dataplane chart's CRDs.
#
# Two responsibilities:
#
#   (a) Pull the upstream Knative CRDs at the version pinned in ../VERSION and
#       write one `crd-<name>.yaml` per CRD into charts/dataplane/crds/:
#
#       (a1) knative/serving's `serving-crds.yaml` — 12 serving CRDs in groups
#            *.serving.knative.dev, *.networking.internal.knative.dev,
#            *.autoscaling.internal.knative.dev, *.caching.internal.knative.dev
#
#       (a2) knative/operator's `operator.yaml` filtered to `operator.knative.dev`
#            group — 2 operator CRDs (knativeservings, knativeeventings).
#            These are needed by the knative-operator subchart to create
#            KnativeServing/KnativeEventing resources. They live here (in the
#            top-level chart's crds/) rather than only in the subchart's crds/
#            because Helm 3 silently skips crds/ directories in subcharts.
#
#   (b) Mirror EVERY `charts/dataplane/crds/crd-*.yaml` file (the 14 knative
#       CRDs from (a) PLUS any non-knative CRDs in the chart dir,
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

echo "==> Vendoring Knative CRDs (serving + operator) at version ${VERSION}"
echo "    chart dir : ${CHART_OUT}"
echo "    mirror dir: ${MIRROR_OUT}"

mkdir -p "${CHART_OUT}" "${MIRROR_OUT}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# (a1) Serving CRDs from knative/serving.
curl -fsSL "https://github.com/knative/serving/releases/download/knative-${VERSION}/serving-crds.yaml" \
  > "${TMPDIR}/serving-crds.yaml"

# (a2) Operator CRDs from knative/operator (filter to operator.knative.dev group only).
curl -fsSL "https://github.com/knative/operator/releases/download/knative-${VERSION}/operator.yaml" \
  > "${TMPDIR}/operator-full.yaml"
yq eval-all 'select(.kind == "CustomResourceDefinition" and .spec.group == "operator.knative.dev")' \
  "${TMPDIR}/operator-full.yaml" > "${TMPDIR}/operator-crds.yaml"

# (a) Refresh ALL knative CRDs in the chart dir. Wipe the entire *.knative.dev.yaml
#     subset; non-knative files (crd-flyteworkflows.yaml etc.) stay in place.
shopt -s nullglob
for f in "${CHART_OUT}"/crd-*.knative.dev.yaml; do rm -f "${f}"; done
shopt -u nullglob

_write_crds() {
  local src_file="$1" source_label="$2" count_var="$3"
  local count=0
  local doc_count
  doc_count="$(yq eval-all '. | document_index' "${src_file}" | sort -nu | tail -1)"
  for i in $(seq 0 "${doc_count}"); do
    local kind crd_name doc
    kind="$(yq eval-all "select(document_index == ${i}) | .kind // \"\"" "${src_file}")"
    [[ "${kind}" == "CustomResourceDefinition" ]] || continue
    crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${src_file}")"
    [[ -n "${crd_name}" && "${crd_name}" != "null" ]] || continue
    doc="$(yq eval-all "select(document_index == ${i})" "${src_file}")"
    {
      echo "# AUTO-GENERATED — do not edit. Run crds/dataplane/scripts/sync.sh to regenerate."
      echo "# Source: ${source_label}"
      echo "${doc}"
    } > "${CHART_OUT}/crd-${crd_name}.yaml"
    count=$((count + 1))
  done
  eval "${count_var}=${count}"
}

serving_count=0
operator_count=0
_write_crds "${TMPDIR}/serving-crds.yaml" \
  "knative/serving release knative-${VERSION}/serving-crds.yaml" serving_count
_write_crds "${TMPDIR}/operator-crds.yaml" \
  "knative/operator release knative-${VERSION}/operator.yaml (operator.knative.dev CRDs filtered)" operator_count

# (b) Mirror EVERY CRD in the chart dir to the SSA-install mirror dir.
#     Includes serving CRDs, operator CRDs, and any non-knative CRDs the
#     chart ships (e.g. crd-flyteworkflows.yaml).
rm -f "${MIRROR_OUT}"/crd-*.yaml

mirror_count=0
shopt -s nullglob
for src in "${CHART_OUT}"/crd-*.yaml; do
  base="$(basename "${src}")"
  cp "${src}" "${MIRROR_OUT}/${base}"
  mirror_count=$((mirror_count + 1))
done
shopt -u nullglob

echo "==> Wrote ${serving_count} serving + ${operator_count} operator CRD(s) to chart dir"
echo "==> Mirrored ${mirror_count} CRD(s) to mirror dir"
