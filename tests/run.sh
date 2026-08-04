#!/usr/bin/env bash

# Test files are in the form of <chart>-<name>.yaml

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
GEN_DIR=${SCRIPT_DIR}/generated
TMP_DIR=${SCRIPT_DIR}/tmp
VALUES_DIR=${SCRIPT_DIR}/values
CHARTS_DIR=${SCRIPT_DIR}/../charts


# Echo the --values flags a fixture needs, from its `# helm-values:` header.
# Used by both generate and expect-fail-tests so the two see identical inputs.
function layered_values_flags {
  local file=$1
  local chart=$2
  local flags=""
  local line
  line=$(head -n 10 "${file}" | grep "^# helm-values:" || true)
  if [[ -n "${line}" ]]; then
    local names
    names=$(echo "${line}" | sed 's/^# helm-values: *//')
    IFS=',' read -ra arr <<< "${names}"
    for name in "${arr[@]}"; do
      name=$(echo "${name}" | xargs)
      if [[ -f "${CHARTS_DIR}/${chart}/${name}" ]]; then
        flags="${flags} --values ${CHARTS_DIR}/${chart}/${name}"
      fi
    done
  fi
  echo "${flags}"
}

# Echo the expected-failure substring from a fixture's `# expect-fail:` header,
# or nothing if it is a normal snapshot fixture.
function expect_fail_substring {
  head -n 10 "$1" | grep "^# expect-fail:" | sed 's/^# expect-fail: *//' || true
}

function generate {
  TARGET_DIR=$1
  echo "Generating test files..."

  # Track which charts we've already processed dependencies for
  processed_charts=""

  # First, add all helm repos once
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm repo add unionai https://unionai.github.io/helm-charts
  helm repo add fluent https://fluent.github.io/helm-charts
  helm repo add opencost https://opencost.github.io/opencost-helm-chart
  helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add flyte https://helm.flyte.org
  helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable

  for file in ${VALUES_DIR}/*.yaml; do
    OUTPUT=$(basename ${file})
    CHART=$(basename ${file} | cut -d. -f1)
    TEST=$(basename ${file} | cut -d. -f2)
    echo "* Generating test output for ${CHART} (${TEST})"

    # Only run dependency commands once per chart
    if [[ ! " ${processed_charts} " =~ " ${CHART} " ]]; then
      echo "  - Building dependencies for chart ${CHART}"
      helm dep update ${CHARTS_DIR}/${CHART}
      helm dependency build ${CHARTS_DIR}/${CHART}
      processed_charts="${processed_charts} ${CHART}"
    fi

    if [[ -n "$(expect_fail_substring ${file})" ]]; then
      echo "  - expect-fail fixture; no snapshot generated"
      continue
    fi

    ADDITIONAL_VALUES=$(layered_values_flags "${file}" "${CHART}")

    helm template ${CHARTS_DIR}/${CHART} \
      --namespace union \
      --kube-version 1.32.0 \
      ${ADDITIONAL_VALUES} \
      --values ${file} > ${TARGET_DIR}/${OUTPUT}
  done
}

# Run the tests
function helm-tests {
  echo "Running helm output tests..."
  mkdir -p "${TMP_DIR}"
  rm -f "${TMP_DIR:?}"/*.yaml
  generate ${TMP_DIR}
  for file in  ${TMP_DIR}/*.yaml; do
    OUTPUT=$(basename ${file})
    diff -u ${GEN_DIR}/${OUTPUT} ${file}
    if [ $? -ne 0 ]; then
      echo "Test failed!"
      exit 1
    fi
  done
}

function kubeconform-tests {
  echo "Running kubeconform tests..."
  for file in ${GEN_DIR}/*.yaml; do
    OUTPUT=$(basename ${file})
    kubeconform -ignore-missing-schemas -skip CustomResourceDefinition ${file}
    if [ $? -ne 0 ]; then
      echo "Test failed!"
      exit 1
    fi
  done
}

# Fixtures carrying `# expect-fail: <substring>` assert that `helm template`
# EXITS NON-ZERO and says why. They exist because some values combinations are
# unsatisfiable rather than merely unusual -- a component needing a
# cluster-scoped grant under low_privilege cannot be degraded into something
# useful -- and the chart should say so at template time instead of installing
# green and failing at runtime. No snapshot is written for these.
function expect-fail-tests {
  echo "Running expect-fail tests..."
  local failed=0
  for file in ${VALUES_DIR}/*.yaml; do
    local substr
    substr=$(expect_fail_substring "${file}")
    [[ -z "${substr}" ]] && continue

    local chart output
    chart=$(basename ${file} | cut -d. -f1)
    echo "* $(basename ${file}) must fail with: ${substr}"

    local values_flags
    values_flags=$(layered_values_flags "${file}" "${chart}")

    if output=$(helm template ${CHARTS_DIR}/${chart} \
        --namespace union \
        --kube-version 1.32.0 \
        ${values_flags} \
        --values ${file} 2>&1); then
      echo "  FAIL: render succeeded but was expected to fail"
      failed=1
      continue
    fi

    if ! echo "${output}" | grep -qF "${substr}"; then
      echo "  FAIL: render failed but the message did not contain the expected text"
      echo "  --- actual ---"
      echo "${output}" | tail -20
      failed=1
      continue
    fi
    echo "  ok"
  done
  if [[ ${failed} -ne 0 ]]; then
    echo "Test failed!"
    exit 1
  fi
}

if [ $# -ne 1 ] ; then
  echo "Usage: $0 <command>"
  exit 1
fi

case $1 in
  helm)
    helm-tests
    ;;
  kubeconform)
    kubeconform-tests
    ;;
  expect-fail)
    expect-fail-tests
    ;;
  generate)
    generate ${GEN_DIR}
    ;;
  *)
    echo "Unknown command $1"
    exit 1
    ;;
esac
