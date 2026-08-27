#!/usr/bin/env bash
#
# Re-vendor the two Knative Operator-type CRDs (`knativeservings` and
# `knativeeventings` in the `operator.knative.dev` group) at the version
# pinned in ../VERSION. Pulled from `knative/operator`'s `operator.yaml`
# release manifest (which also bundles RBAC + a Deployment, all filtered
# out — we only keep CRD documents).
#
# Knative *serving* CRDs (12 in groups *.serving.knative.dev,
# *.networking.internal.knative.dev, *.autoscaling.internal.knative.dev,
# *.caching.internal.knative.dev) are NOT vendored here — they live in
# `crds/dataplane/` because the dataplane chart needs them in both
# zero-trust mode (subchart disabled) and legacy mode (subchart enabled),
# so the parent chart is the right home. This dir holds only the 2 Operator-
# type CRDs the knative-operator subchart needs on top of those.
#
# When the knative-operator subchart itself is eventually retired (zero-trust
# becomes the only mode), this entire dir + charts/knative-operator/crds/
# can be deleted — these 2 CRDs have no consumer outside the subchart.
#
# Writes one `crd-<name>.yaml` per CRD to TWO byte-identical locations:
#
#   - crds/knative-operator/         → SSA-install mirror (--skip-crds path /
#                                      dedicated ArgoCD Application)
#   - charts/knative-operator/crds/  → consumed by Helm's chart `crds/`
#                                      convention so the subchart auto-installs
#                                      them on a default `helm install`
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

echo "==> Vendoring Knative Operator-type CRDs at version ${VERSION}"
echo "    vendored mirror dir: ${OUT_DIR}"
echo "    chart crds dir:      ${CHART_OUT_DIR}"

mkdir -p "${OUT_DIR}"
mkdir -p "${CHART_OUT_DIR}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# knative/operator's operator.yaml bundles CRDs, Deployment, RBAC, etc.
# We only want the CRD documents — and of those, only the 2 in the
# `operator.knative.dev` group (knativeservings, knativeeventings). The
# manifest also includes serving CRDs duplicated from knative/serving;
# those live in crds/dataplane/ and are filtered out here to avoid
# double-vendoring.
curl -fsSL "https://github.com/knative/operator/releases/download/knative-${VERSION}/operator.yaml" \
  > "${TMPDIR}/operator-full.yaml"
yq eval-all '
  select(.kind == "CustomResourceDefinition" and .spec.group == "operator.knative.dev")
' "${TMPDIR}/operator-full.yaml" > "${TMPDIR}/operator-crds.yaml"

# Wipe existing CRDs in both output dirs so removals upstream propagate.
rm -f "${OUT_DIR}"/crd-*.yaml
rm -f "${CHART_OUT_DIR}"/crd-*.yaml

count=0
source_label="knative/operator release knative-${VERSION}/operator.yaml (operator.knative.dev CRDs filtered)"
doc_count="$(yq eval-all '. | document_index' "${TMPDIR}/operator-crds.yaml" | sort -nu | tail -1)"

for i in $(seq 0 "${doc_count}"); do
  kind="$(yq eval-all "select(document_index == ${i}) | .kind // \"\"" "${TMPDIR}/operator-crds.yaml")"
  [[ "${kind}" == "CustomResourceDefinition" ]] || continue

  crd_name="$(yq eval-all "select(document_index == ${i}) | .metadata.name" "${TMPDIR}/operator-crds.yaml")"
  [[ -n "${crd_name}" && "${crd_name}" != "null" ]] || continue

  doc="$(yq eval-all "select(document_index == ${i})" "${TMPDIR}/operator-crds.yaml")"

  payload="$(
    echo "# AUTO-GENERATED — do not edit. Run \`make vendor-crds\` from the repo root to regenerate."
    echo "# Source: ${source_label}"
    echo "${doc}"
  )"

  echo "${payload}" > "${OUT_DIR}/crd-${crd_name}.yaml"
  echo "${payload}" > "${CHART_OUT_DIR}/crd-${crd_name}.yaml"

  count=$((count + 1))
done

echo "==> Wrote ${count} operator CRD manifests to each output dir"
