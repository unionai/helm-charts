#!/usr/bin/env bash
#
# Verify vendored Knative Serving CRDs in this directory AND the matching
# Helm `crds/` copies under charts/dataplane/crds/ match a fresh sync.sh
# re-pull from upstream at the pinned VERSION. Catches:
#   - hand edits to either copy
#   - chart-dir copy drifting from the mirror
#   - upstream-at-same-tag content changes (release retags, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CRD_DIR}/../.." && pwd)"

CHART_DIR="${REPO_ROOT}/charts/dataplane/crds"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
TMP_CHART="${TMPDIR}/chart"
TMP_MIRROR="${TMPDIR}/mirror"
mkdir -p "${TMP_CHART}" "${TMP_MIRROR}"

# Preserve any non-Knative CRDs already in the chart dir (e.g. crd-flyteworkflows.yaml)
# so the chart-dir comparison below doesn't flag them as missing.
shopt -s nullglob
for f in "${CHART_DIR}"/*.yaml; do
  case "$(basename "${f}")" in
    crd-*.knative.dev.yaml) ;;
    *) cp "${f}" "${TMP_CHART}/" ;;
  esac
done
shopt -u nullglob

"${SCRIPT_DIR}/sync.sh" "${TMP_CHART}" "${TMP_MIRROR}" >/dev/null

mismatch=0
shopt -s nullglob

# Compare chart-dir copies.
for src in "${CHART_DIR}"/*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${TMP_CHART}/${base}" ]]; then
    echo "drift: extra chart-dir file (not produced by sync.sh): charts/dataplane/crds/${base}" >&2
    mismatch=1
    continue
  fi
  if ! diff -u "${src}" "${TMP_CHART}/${base}" >&2; then
    mismatch=1
  fi
done
for src in "${TMP_CHART}"/*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${CHART_DIR}/${base}" ]]; then
    echo "drift: missing chart-dir file (would be produced by sync.sh): charts/dataplane/crds/${base}" >&2
    mismatch=1
  fi
done

# Compare mirror copies.
for src in "${CRD_DIR}"/crd-*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${TMP_MIRROR}/${base}" ]]; then
    echo "drift: extra mirror file (not produced by sync.sh): crds/dataplane/${base}" >&2
    mismatch=1
    continue
  fi
  if ! diff -u "${src}" "${TMP_MIRROR}/${base}" >&2; then
    mismatch=1
  fi
done
for src in "${TMP_MIRROR}"/crd-*.yaml; do
  base="$(basename "${src}")"
  if [[ ! -f "${CRD_DIR}/${base}" ]]; then
    echo "drift: missing mirror file (would be produced by sync.sh): crds/dataplane/${base}" >&2
    mismatch=1
  fi
done

shopt -u nullglob

if (( mismatch != 0 )); then
  cat >&2 <<EOF

ERROR: vendored Knative CRDs do not match a fresh sync.sh re-pull from upstream.
Run \`make vendor-crds\` and commit the result.
EOF
  exit 1
fi

VERSION="$(cat "${CRD_DIR}/VERSION" | tr -d '[:space:]')"
chart_count="$(ls "${CHART_DIR}"/crd-*.knative.dev.yaml 2>/dev/null | wc -l | tr -d ' ')"
mirror_count="$(ls "${CRD_DIR}"/crd-*.yaml 2>/dev/null | wc -l | tr -d ' ')"
echo "==> dataplane Knative CRDs in sync (version ${VERSION}, ${chart_count} chart-dir + ${mirror_count} mirror files)"
