#!/usr/bin/env bash
#
# Script to install or update ScyllaDB Operator CRDs
#
# This script extracts CRDs from the scylla-operator Helm chart and applies them
# to the cluster. This is necessary because Helm does not properly manage CRD
# lifecycle updates.
#
# Usage:
#   ./install-scylla-crds.sh [version]
#
# Arguments:
#   version - ScyllaDB operator version (default: v1.18.1)
#
# Examples:
#   ./install-scylla-crds.sh           # Install version v1.18.1 (default)
#   ./install-scylla-crds.sh v1.18.1   # Install specific version

set -euo pipefail

# Default version (should match Chart.yaml scylla-operator version)
VERSION="${1:-v1.18.1}"
REPO_NAME="scylla-operator"
REPO_URL="https://scylla-operator-charts.storage.googleapis.com/stable"
CHART_NAME="scylla-operator"

echo "==> Installing ScyllaDB Operator CRDs (version: ${VERSION})"

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed. Please install Helm first."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed. Please install kubectl first."
    exit 1
fi

# Add or update the Helm repository
echo "==> Adding/updating Helm repository: ${REPO_NAME}"
helm repo add "${REPO_NAME}" "${REPO_URL}" 2>/dev/null || helm repo add "${REPO_NAME}" "${REPO_URL}" --force-update
helm repo update "${REPO_NAME}"

# Create temporary directory
echo "==> Creating temporary directory"
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

# Pull the chart
echo "==> Pulling ${CHART_NAME} chart version ${VERSION}"
helm pull "${REPO_NAME}/${CHART_NAME}" \
    --version "${VERSION}" \
    --untar \
    --untardir "${TMPDIR}"

# Check if CRDs exist
CRD_DIR="${TMPDIR}/${CHART_NAME}/crds"
if [ ! -d "${CRD_DIR}" ]; then
    echo "ERROR: CRD directory not found in chart: ${CRD_DIR}"
    exit 1
fi

# Count CRDs
CRD_COUNT=$(find "${CRD_DIR}" -name "*.yaml" -o -name "*.yml" | wc -l | tr -d ' ')
if [ "${CRD_COUNT}" -eq 0 ]; then
    echo "ERROR: No CRD files found in ${CRD_DIR}"
    exit 1
fi

echo "==> Found ${CRD_COUNT} CRD file(s)"

# Apply CRDs with server-side apply
echo "==> Applying CRDs to cluster"
kubectl apply --server-side -f "${CRD_DIR}/"

echo ""
echo "==> ✓ ScyllaDB Operator CRDs installed successfully!"
echo ""
echo "You can now install the control plane chart with scylla.enabled=true:"
echo "  helm install my-controlplane ./controlplane -f values-scylla-example.yaml"
echo ""
