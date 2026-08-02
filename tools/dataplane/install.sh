#!/usr/bin/env bash
# tools/dataplane/install.sh — shared cluster-side deploy helpers for the Union
# dataplane (and controlplane) charts.
#
# Called by BOTH the local k3d repro (tools/dataplane/k3d/up.sh) and CI
# (.github/workflows/*-integration.yaml), so the CRD-apply, subchart-dependency,
# and health-gate logic has ONE source of truth — no more "mirrors the k3d repo
# set" hand-sync between up.sh and release-integration.yaml.
#
# Run from the repo root; paths are repo-relative.
#
# Subcommands:
#   crds   <dir>...          kubectl apply the CRDs under each dir (server-side, force-conflicts)
#   deps   <chart-dir>...    add the pinned helm repos, then build/update deps for each chart
#   health <namespace>...    wait for rollouts + fail on any crashlooping / not-ready pod
set -euo pipefail

# Helm repositories the dataplane/controlplane subcharts pull from.
# SINGLE SOURCE OF TRUTH (was duplicated in up.sh and release-integration.yaml).
_REPOS=(
  "prometheus-community https://prometheus-community.github.io/helm-charts"
  "fluent https://fluent.github.io/helm-charts"
  "metrics-server https://kubernetes-sigs.github.io/metrics-server/"
  "opencost https://opencost.github.io/opencost-helm-chart"
  "nvidia https://nvidia.github.io/dcgm-exporter/helm-charts"
  "ingress-nginx https://kubernetes.github.io/ingress-nginx"
  "unionai https://unionai.github.io/helm-charts"
)

cmd_crds() {
  [ "$#" -ge 1 ] || { echo "usage: install.sh crds <dir>..." >&2; return 2; }
  local d
  for d in "$@"; do
    echo ">> [crds] kubectl apply $d"
    kubectl apply --server-side --force-conflicts -f "$d/" >/dev/null
  done
}

cmd_deps() {
  [ "$#" -ge 1 ] || { echo "usage: install.sh deps <chart-dir>..." >&2; return 2; }
  local r
  for r in "${_REPOS[@]}"; do
    # shellcheck disable=SC2086  # $r is "name url" — intentional word split
    helm repo add $r >/dev/null 2>&1 || true
  done
  local chart updated=""
  for chart in "$@"; do
    if [ -n "$(ls -A "$chart/charts" 2>/dev/null)" ]; then
      # Vendored subcharts already present (e.g. a restored CI cache) — build offline.
      echo ">> [deps] helm dependency build $chart"
      helm dependency build "$chart" >/dev/null
    else
      [ -n "$updated" ] || { helm repo update >/dev/null 2>&1; updated=1; }
      echo ">> [deps] helm dependency update $chart"
      helm dependency update "$chart" >/dev/null
    fi
  done
}

cmd_health() {
  [ "$#" -ge 1 ] || { echo "usage: install.sh health <namespace>..." >&2; return 2; }
  local ns
  for ns in "$@"; do
    echo ">> [health] namespace $ns"
    kubectl -n "$ns" rollout status deploy --timeout=10m
    kubectl -n "$ns" wait --for=condition=Available --all deploy --timeout=5m
    # Some components reconcile ASYNC after helm returns (knative kourier gateway
    # is created only once KnativeServing reconciles), so poll for convergence.
    # A real config crashloop stays bad for the whole window and still fails.
    # Ignore Terminating pods (old replicas from an in-place rollout).
    local deadline=$((SECONDS + 300)) bad=""
    while :; do
      bad=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
        | awk '{split($2,a,"/"); if ($3 != "Terminating" && ($3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/ || ($3 != "Completed" && a[1] != a[2]))) print}')
      [ -z "$bad" ] && break
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "ERROR: unhealthy pods in $ns after install (still bad after grace period):" >&2
        echo "$bad" >&2
        return 1
      fi
      echo ">> [health] $ns not yet converged; re-checking in 15s"
      sleep 15
    done
  done
}

main() {
  [ "$#" -ge 1 ] || { echo "usage: install.sh {crds|deps|health} ..." >&2; return 2; }
  local sub="$1"; shift
  case "$sub" in
    crds)   cmd_crds "$@" ;;
    deps)   cmd_deps "$@" ;;
    health) cmd_health "$@" ;;
    *) echo "unknown subcommand: $sub (expected crds|deps|health)" >&2; return 2 ;;
  esac
}

main "$@"
