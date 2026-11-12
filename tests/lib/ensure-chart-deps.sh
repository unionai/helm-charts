#!/usr/bin/env bash
#
# Vendor each chart's subcharts into <chart>/charts/, touching the network
# only when what is vendored does not already match Chart.yaml.
#
#   tests/lib/ensure-chart-deps.sh CHART...
#
# Every dependency in this repo is pinned to an exact version, so when
# `helm dependency list` (which reads only local files) reports each one "ok",
# the archive in charts/ is that name at that version and an update would
# fetch the same thing again. Otherwise `helm dependency build` restores
# charts/ from a Chart.lock still in step with Chart.yaml, using the cached
# repo indexes; and when that cannot work (no lock, a stale one after a
# version bump, or no cached index) `helm dependency update` resolves
# Chart.yaml against the repos, as before.

set -euo pipefail

# An exact version, as opposed to a range such as ^1.2.0 or 1.x, which would
# let a refresh pick a newer release than the one vendored.
EXACT='^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'

function vendored {
  local chart=$1 listing
  listing=$(helm dependency list "${chart}" 2>/dev/null) || return 1
  # Header, then NAME VERSION REPOSITORY STATUS; "wrong version" et al. end in
  # something other than "ok".
  awk -v exact="${EXACT}" '
    NR == 1 || NF == 0 { next }
    $2 !~ exact || $NF != "ok" { bad = 1 }
    END { exit bad }
  ' <<<"${listing}"
}

for chart in "$@"; do
  if vendored "${chart}"; then
    echo "  - ${chart}: subcharts already vendored at the pinned versions"
    continue
  fi
  if ! helm dependency build --skip-refresh "${chart}"; then
    echo "  - ${chart}: no usable Chart.lock or cached index; running helm dependency update"
    helm dependency update "${chart}"
  fi
done
