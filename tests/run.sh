#!/usr/bin/env bash

# Snapshot test driver for the Helm charts in ../charts/.
#
# Each tests/values/<chart>.<test>.yaml is rendered with `helm template` and
# either written to tests/generated/ (the `generate` subcommand) or rendered
# into tests/tmp/ and diff'd against tests/generated/ (the `helm` subcommand).
# `kubeconform` subcommand validates the committed tests/generated/ files
# against k8s schemas.
#
# Per-fixture values files can be augmented by a top-of-file directive:
#     # helm-values: values.foo.yaml,values.bar.yaml
# Each listed file is resolved relative to charts/<chart>/ and added as
# `--values` before the fixture file itself, so the fixture still wins last.

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
GEN_DIR=${SCRIPT_DIR}/generated
TMP_DIR=${SCRIPT_DIR}/tmp
VALUES_DIR=${SCRIPT_DIR}/values
CHARTS_DIR=${SCRIPT_DIR}/../charts
KC_CACHE_DIR=${SCRIPT_DIR}/.kubeconform-cache
DEP_SENTINEL_DIR=${SCRIPT_DIR}/.dep-sentinels

# Charts whose fixtures live in tests/values/. Discovered dynamically by
# looking at the unique <chart> prefix of each fixture filename, so adding
# a new chart's fixtures just works without editing this script.
discover_charts() {
  local seen=""
  for f in "${VALUES_DIR}"/*.yaml; do
    local c
    c=$(basename "${f}" | cut -d. -f1)
    case " ${seen} " in
      *" ${c} "*) ;;
      *) seen="${seen} ${c}" ;;
    esac
  done
  echo "${seen}"
}

# Parallelism for `helm template` fan-out. Override via PARALLEL=N.
PARALLEL=${PARALLEL:-8}

# ----- dependency build -------------------------------------------------------
# Skip `helm dep update` entirely: it bumps Chart.lock against live indexes,
# which is a developer action, not a test action, and was the dominant
# cost (~25s per chart) of the legacy script. We only need `helm dep build`,
# and only when charts/<chart>/charts/ is missing or out of sync with
# Chart.lock. The sentinel encodes sha256(Chart.lock), so re-runs are free
# until the lock changes.

# `helm dep build` needs the relevant repos to be known to helm. We register
# only the ones referenced by current Chart.yaml/Chart.lock — adding repos is
# cheap (a YAML write) so this is idempotent and safe to run every time.
ensure_helm_repos() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add metrics-server        https://kubernetes-sigs.github.io/metrics-server/  >/dev/null 2>&1 || true
  helm repo add fluent                https://fluent.github.io/helm-charts               >/dev/null 2>&1 || true
  helm repo add opencost              https://opencost.github.io/opencost-helm-chart     >/dev/null 2>&1 || true
  helm repo add nvidia                https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null 2>&1 || true
  helm repo add ingress-nginx         https://kubernetes.github.io/ingress-nginx         >/dev/null 2>&1 || true
  helm repo add flyte                 https://helm.flyte.org                             >/dev/null 2>&1 || true
  helm repo add scylla                https://scylla-operator-charts.storage.googleapis.com/stable >/dev/null 2>&1 || true
}

# Hash a chart's Chart.lock (or Chart.yaml if no deps). Used as a sentinel so
# we skip `helm dep build` when the on-disk charts/ already matches the lock.
chart_dep_hash() {
  local chart_dir=$1
  local src
  if [[ -f "${chart_dir}/Chart.lock" ]]; then
    src="${chart_dir}/Chart.lock"
  else
    src="${chart_dir}/Chart.yaml"
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${src}" | cut -d' ' -f1
  else
    sha256sum "${src}" | cut -d' ' -f1
  fi
}

build_chart_deps() {
  local chart_dir=$1
  local chart_name
  chart_name=$(basename "${chart_dir}")

  # Charts with no dependencies block in Chart.yaml: nothing to build.
  if ! grep -q '^dependencies:' "${chart_dir}/Chart.yaml"; then
    return 0
  fi

  # Sentinel lives outside the chart tree because `helm dep build` wipes and
  # re-creates charts/<chart>/charts/, which would clobber any marker inside.
  local hash sentinel
  hash=$(chart_dep_hash "${chart_dir}")
  sentinel="${DEP_SENTINEL_DIR}/${chart_name}-${hash}"

  # Sentinel valid only if both it AND the populated charts/ dir exist —
  # someone might have manually `rm -rf charts/<chart>/charts/` while the
  # sentinel persisted.
  if [[ -f "${sentinel}" && -d "${chart_dir}/charts" ]] \
    && find "${chart_dir}/charts" -maxdepth 1 -name '*.tgz' -print -quit | grep -q .; then
    return 0
  fi

  echo "  - Building dependencies for chart ${chart_name}"
  helm dep build "${chart_dir}" >/dev/null
  mkdir -p "${DEP_SENTINEL_DIR}"
  rm -f "${DEP_SENTINEL_DIR}/${chart_name}-"* 2>/dev/null || true
  touch "${sentinel}"
}

prepare_deps() {
  ensure_helm_repos
  for chart in $(discover_charts); do
    build_chart_deps "${CHARTS_DIR}/${chart}"
  done
}

# ----- helm template fan-out --------------------------------------------------
# Render one fixture. Reads optional `# helm-values:` directive from the
# fixture file and stacks extra values files (resolved against the chart dir)
# before the fixture itself.
render_one() {
  local fixture=$1
  local target_dir=$2
  local output chart extra additional_line
  output=$(basename "${fixture}")
  chart=$(basename "${fixture}" | cut -d. -f1)

  extra=()
  additional_line=$(head -n 10 "${fixture}" | grep "^# helm-values:" || true)
  if [[ -n "${additional_line}" ]]; then
    local values_files
    values_files=$(echo "${additional_line}" | sed 's/^# helm-values: *//')
    IFS=',' read -ra arr <<< "${values_files}"
    for val_file in "${arr[@]}"; do
      val_file=$(echo "${val_file}" | xargs)
      if [[ -f "${CHARTS_DIR}/${chart}/${val_file}" ]]; then
        extra+=(--values "${CHARTS_DIR}/${chart}/${val_file}")
      else
        echo "  - WARNING: Additional values file not found: ${val_file}" >&2
      fi
    done
  fi

  helm template "${CHARTS_DIR}/${chart}" \
    --namespace union \
    --kube-version 1.32.0 \
    "${extra[@]}" \
    --values "${fixture}" \
    > "${target_dir}/${output}"
}
export -f render_one
# CHARTS_DIR is read inside render_one when subshells fan out via xargs.
export CHARTS_DIR

generate() {
  local target_dir=$1
  echo "Generating test files into ${target_dir}..."
  prepare_deps

  mkdir -p "${target_dir}"

  # Fan out across $PARALLEL workers. xargs propagates non-zero from the
  # function and aborts the run. We pipe the fixture list to keep ordering
  # stable in logs.
  local fixtures=()
  while IFS= read -r f; do
    fixtures+=("$f")
  done < <(find "${VALUES_DIR}" -maxdepth 1 -name '*.yaml' -print | sort)

  printf '%s\n' "${fixtures[@]}" \
    | xargs -n 1 -P "${PARALLEL}" -I {} bash -c 'render_one "$1" "$2"' _ {} "${target_dir}"
}

# ----- subcommands ------------------------------------------------------------
helm-tests() {
  echo "Running helm output tests..."
  mkdir -p "${TMP_DIR}"
  rm -f "${TMP_DIR:?}"/*.yaml
  generate "${TMP_DIR}"

  # Collect all drift, then fail at the end so a single CI run surfaces every
  # snapshot that needs regenerating instead of stopping at the first.
  local fail=0
  for file in "${TMP_DIR}"/*.yaml; do
    local name
    name=$(basename "${file}")
    if ! diff -u "${GEN_DIR}/${name}" "${file}"; then
      fail=1
    fi
  done
  if [[ ${fail} -ne 0 ]]; then
    echo "Snapshot drift detected. Run 'make generate-expected' to regenerate." >&2
    exit 1
  fi
}

kubeconform-tests() {
  echo "Running kubeconform tests..."
  mkdir -p "${KC_CACHE_DIR}"
  # Single invocation across the whole directory: ~10x faster than the
  # per-file loop, plus the on-disk schema cache eliminates repeat downloads.
  kubeconform \
    -ignore-missing-schemas \
    -skip CustomResourceDefinition \
    -cache "${KC_CACHE_DIR}" \
    -n "${PARALLEL}" \
    -summary \
    "${GEN_DIR}"
}

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <generate|helm|kubeconform>"
  exit 1
fi

case $1 in
  helm)        helm-tests ;;
  kubeconform) kubeconform-tests ;;
  generate)    generate "${GEN_DIR}" ;;
  *)           echo "Unknown command $1"; exit 1 ;;
esac
