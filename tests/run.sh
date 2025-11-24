#!/usr/bin/env bash

# Test files are in the form of <chart>-<name>.yaml

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
GEN_DIR=${SCRIPT_DIR}/generated
TMP_DIR=${SCRIPT_DIR}/tmp
VALUES_DIR=${SCRIPT_DIR}/values
CHARTS_DIR=${SCRIPT_DIR}/../charts

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

    # Check for additional values files specified in comments
    ADDITIONAL_VALUES=""
    HELM_VALUES_LINE=$(head -n 10 ${file} | grep "^# helm-values:" || true)
    if [[ -n "${HELM_VALUES_LINE}" ]]; then
      # Extract the values file names from the comment
      VALUES_FILES=$(echo "${HELM_VALUES_LINE}" | sed 's/^# helm-values: *//')
      # Split by comma and build --values flags
      IFS=',' read -ra VALUES_ARRAY <<< "${VALUES_FILES}"
      for val_file in "${VALUES_ARRAY[@]}"; do
        val_file=$(echo "${val_file}" | xargs) # trim whitespace
        if [[ -f "${CHARTS_DIR}/${CHART}/${val_file}" ]]; then
          ADDITIONAL_VALUES="${ADDITIONAL_VALUES} --values ${CHARTS_DIR}/${CHART}/${val_file}"
          echo "  - Including additional values file: ${val_file}"
        else
          echo "  - WARNING: Additional values file not found: ${val_file}"
        fi
      done
    fi

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
  generate)
    generate ${GEN_DIR}
    ;;
  *)
    echo "Unknown command $1"
    exit 1
    ;;
esac
