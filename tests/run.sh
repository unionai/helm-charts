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
  for file in ${VALUES_DIR}/*.yaml; do
    OUTPUT=$(basename ${file})
    CHART=$(basename ${file} | cut -d. -f1)
    TEST=$(basename ${file} | cut -d. -f2)
    echo "* Generating test output for ${CHART} (${TEST})"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
    helm repo add unionai https://unionai.github.io/helm-charts
    helm repo add fluent https://fluent.github.io/helm-charts
    helm repo add opencost https://opencost.github.io/opencost-helm-chart
    helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add flyte https://helm.flyte.org
    helm dependency build ${CHARTS_DIR}/${CHART}
    helm dep update ${CHARTS_DIR}/${CHART}
    helm template ${CHARTS_DIR}/${CHART} \
      --namespace union \
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
