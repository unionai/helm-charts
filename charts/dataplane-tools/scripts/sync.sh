#!/usr/bin/env bash
#
# Mirror the dataplane chart's Grafana dashboards into the dataplane-tools chart.
#
# charts/dataplane/dashboards/ is the single source of truth for the dataplane
# observability dashboards (the DP's kube-prometheus-stack Grafana consumes them
# as ConfigMaps). dataplane-tools ships its OWN Grafana (a Knative Service) and
# can only embed files that live inside its own chart directory — Helm's .Files
# is chart-scoped — so we vendor a byte-identical copy here. scripts/check.sh is
# the drift gate (run in CI + `make test`) that keeps the two in lockstep.
#
# Usage:
#   ./scripts/sync.sh            # writes into charts/dataplane-tools/dashboards/
#   ./scripts/sync.sh OUT_DIR    # write to a custom dir (used by check.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CHART_DIR}/../.." && pwd)"

SRC_DIR="${REPO_ROOT}/charts/dataplane/dashboards"
OUT_DIR="${1:-${CHART_DIR}/dashboards}"

if [ ! -d "${SRC_DIR}" ]; then
  echo "ERROR: source dashboards dir not found: ${SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

# Drop stale copies first so an upstream deletion propagates on the next sync.
shopt -s nullglob
for f in "${OUT_DIR}"/*.json; do
  rm -f "${f}"
done

count=0
for f in "${SRC_DIR}"/*.json; do
  cp "${f}" "${OUT_DIR}/"
  count=$((count + 1))
done
shopt -u nullglob

echo "synced ${count} dashboard(s): ${SRC_DIR} -> ${OUT_DIR}"
