#!/usr/bin/env bash
#
# Drift gate: charts/dataplane-tools/dashboards/ must byte-match a fresh sync
# from charts/dataplane/dashboards/. Fails (non-zero) on any drift — a hand edit
# to the vendored copy, or an upstream dashboard change that wasn't re-synced.
#
# Fix drift with:  ./charts/dataplane-tools/scripts/sync.sh   (or make sync-tool-dashboards)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDORED="${CHART_DIR}/dashboards"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

"${SCRIPT_DIR}/sync.sh" "${TMPDIR}" >/dev/null

if ! diff -ru "${VENDORED}" "${TMPDIR}"; then
  echo "" >&2
  echo "ERROR: charts/dataplane-tools/dashboards/ is out of sync with charts/dataplane/dashboards/." >&2
  echo "Run: ./charts/dataplane-tools/scripts/sync.sh   (or: make sync-tool-dashboards)" >&2
  exit 1
fi

echo "OK: dataplane-tools dashboards match charts/dataplane/dashboards/"
