#!/usr/bin/env bash
#
# Re-vendor Knative Operator + Serving CRDs at the version pinned in
# ../VERSION. Pulls from two upstream releases:
#
#   - knative/serving:  serving-crds.yaml  (12 CRDs: serving + networking + autoscaling + caching)
#   - knative/operator: operator.yaml      (2 CRDs: knativeservings, knativeeventings — filtered from the full operator manifest)
#
# Writes one `crd-<name>.yaml` per CRD (verbatim from the upstream releases)
# to TWO byte-identical locations:
#
#   - crds/knative-operator/                  → vendored mirror for the
#                                               `--skip-crds` / dedicated
#                                               ArgoCD-Application install
#                                               path.
#   - charts/knative-operator/crds/           → consumed by Helm's chart
#                                               `crds/` convention so the
#                                               subchart auto-installs them
#                                               on a default `helm install`
#                                               (no `--skip-crds`).
#
# Bumping Knative:
#   1. Edit ./VERSION (e.g. v1.17.0).
#   2. Run `make vendor-crds` from the repo root (or this script directly).
#   3. Review diff, run `make check-vendored-crds`, commit.
#
# Usage:
#   ./scripts/sync.sh                                  # default: writes to vendored dir + chart dir
#   ./scripts/sync.sh /path/to/out/dir                 # overrides vendored-mirror output (chart dir still default)
#   ./scripts/sync.sh /path/to/out/dir /chart/out/dir  # overrides both (used by check.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

VERSION_FILE="${CRD_DIR}/VERSION"
OUT_DIR="${1:-${CRD_DIR}}"
CHART_OUT_DIR="${2:-${REPO_ROOT}/charts/knative-operator/crds}"

command -v yq   >/dev/null || { echo "ERROR: yq not found in PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found in PATH" >&2; exit 1; }

VERSION="$(cat "${VERSION_FILE}" | tr -d '[:space:]')"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: ${VERSION_FILE} is empty; set e.g. v1.16.0" >&2
  exit 1
fi

echo "==> Vendoring Knative CRDs at version ${VERSION}"
echo "    vendored mirror dir: ${OUT_DIR}"
echo "    chart crds dir:      ${CHART_OUT_DIR}"

mkdir -p "${OUT_DIR}"
mkdir -p "${CHART_OUT_DIR}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# 1) knative/serving release ships a CRD-only file.
curl -fsSL "https://github.com/knative/serving/releases/download/knative-${VERSION}/serving-crds.yaml" \
  > "${TMPDIR}/serving-crds.yaml"

# 2) knative/operator's operator.yaml bundles CRDs, Deployment, RBAC, etc.
#    We only want the CRD documents.
curl -fsSL "https://github.com/knative/operator/releases/download/knative-${VERSION}/operator.yaml" \
  > "${TMPDIR}/operator-full.yaml"
yq eval-all 'select(.kind == "CustomResourceDefinition")' "${TMPDIR}/operator-full.yaml" \
  > "${TMPDIR}/operator-crds.yaml"

# Wipe existing CRDs in both output dirs so removals upstream propagate.
rm -f "${OUT_DIR}"/crd-*.yaml
rm -f "${CHART_OUT_DIR}"/crd-*.yaml

count=0
write_crd_docs() {
  local src="$1"
  local source_label="$2"

  local doc_count
  doc_count="$(yq eval-all '. | document_index' "${src}" | sort -nu | tail -1)"

  for i in $(seq 0 "${doc_count}"); do
    local kind
    kind="$(yq eval-all "select(document_index == ${i}) | .kind // \"\"" "${src}")"
    if [[ "${kind}" != "CustomResourceDefinition" ]]; then continue; fi

    local crd_name
    crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${src}")"
    if [[ -z "${crd_name}" || "${crd_name}" == "null" ]]; then continue; fi

    local doc
    doc="$(yq eval-all "select(document_index == ${i})" "${src}")"

    local payload
    payload="$(
      echo "# AUTO-GENERATED — do not edit. Run \`make vendor-crds\` from the repo root to regenerate."
      echo "# Source: ${source_label} ${VERSION}"
      echo "${doc}"
    )"

    echo "${payload}" > "${OUT_DIR}/crd-${crd_name}.yaml"
    echo "${payload}" > "${CHART_OUT_DIR}/crd-${crd_name}.yaml"

    count=$((count + 1))
  done
}

write_crd_docs "${TMPDIR}/serving-crds.yaml"   "knative/serving release knative-${VERSION}/serving-crds.yaml"
write_crd_docs "${TMPDIR}/operator-crds.yaml"  "knative/operator release knative-${VERSION}/operator.yaml (CRDs filtered)"

echo "==> Wrote ${count} CRD manifests to each output dir"
