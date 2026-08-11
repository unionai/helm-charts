#!/usr/bin/env bash
# tools/dataplane/install.sh — shared cluster-side deploy helpers for the Union
# dataplane (and controlplane) charts.
#
# Called by BOTH the local k3d repro (tools/dataplane/k3d/up.sh) and CI
# (.github/workflows/*-integration.yaml), so the CRD-apply, subchart-dependency,
# and health-gate logic has ONE source of truth — no more "mirrors the k3d repo
# set" hand-sync between up.sh and integration-checks.yaml.
#
# Run from the repo root; paths are repo-relative.
#
# Subcommands:
#   crds   <dir>...          kubectl apply the CRDs under each dir (server-side, force-conflicts)
#   deps   <chart-dir>...    add the pinned helm repos, then build/update deps for each chart
#   health <namespace>...    wait for rollouts + fail on any crashlooping / not-ready pod
#   restart [--settle N] [--recreate] <ns> [deploy]
#                            restart deployment(s) + wait rollout. Shared by the cloud
#                            legs (apply in-place config helm doesn't roll pods for) and
#                            k3d (operator reconnect). --settle sleeps first; --recreate
#                            scales 0->1 for one <deploy> (avoids surging a 2nd pod).
#   chart <release> <chart-dir> [helm args...]
#                            helm upgrade --install with --take-ownership --wait
#                            --timeout (CHART_TIMEOUT, default 12m) + retry (bundled
#                            operator webhook not ready on first try). Caller passes
#                            -n/-f/--set etc. Shared by all legs (values differ per leg).
set -euo pipefail

# Helm repositories the dataplane/controlplane subcharts pull from.
# SINGLE SOURCE OF TRUTH (was duplicated in up.sh and integration-checks.yaml).
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

cmd_restart() {
  local settle=0 recreate=0
  while :; do case "${1:-}" in
    --settle)   settle="$2"; shift 2 ;;
    --recreate) recreate=1; shift ;;
    *) break ;;
  esac; done
  [ "$#" -ge 1 ] || { echo "usage: install.sh restart [--settle N] [--recreate] <ns> [deploy]" >&2; return 2; }
  local ns="$1" dep="${2:-}"
  [ "$settle" -gt 0 ] && { echo ">> [restart] $ns: settle ${settle}s"; sleep "$settle"; }
  if [ "$recreate" = 1 ]; then
    # Scale 0 -> 1 (not rollout restart) so a 2nd pod isn't surged onto an already
    # CPU-saturated node before the old one exits. Requires a single deployment.
    [ -n "$dep" ] || { echo "restart --recreate requires a <deploy>" >&2; return 2; }
    echo ">> [restart] $ns/$dep: scale 0 -> 1"
    kubectl -n "$ns" scale "deployment/$dep" --replicas=0
    kubectl -n "$ns" wait --for=delete pod -l "app.kubernetes.io/name=$dep" --timeout=120s || true
    kubectl -n "$ns" scale "deployment/$dep" --replicas=1
    kubectl -n "$ns" rollout status "deployment/$dep" --timeout=240s
  elif [ -n "$dep" ]; then
    echo ">> [restart] $ns/$dep: rollout restart"
    kubectl -n "$ns" rollout restart "deployment/$dep"
    kubectl -n "$ns" rollout status "deployment/$dep" --timeout=10m
  else
    echo ">> [restart] $ns: rollout restart all deployments"
    kubectl -n "$ns" rollout restart deployment
    kubectl -n "$ns" rollout status deployment --timeout=10m
  fi
}

cmd_chart() {
  [ "$#" -ge 2 ] || { echo "usage: install.sh chart <release> <chart-dir> [helm args...]" >&2; return 2; }
  local release="$1" chart="$2"; shift 2
  # Retry: the bundled kube-prometheus-stack operator's admission webhook isn't
  # ready when the chart first creates PrometheusRule CRs (harmless no-op on legs
  # that disable monitoring). Callers pass -n / -f <values> / --set per leg.
  local n=0
  until helm upgrade --install "$release" "$chart" "$@" \
          --take-ownership --wait --timeout "${CHART_TIMEOUT:-12m}"; do
    n=$((n+1)); [ "$n" -ge 3 ] && { echo "ERROR: helm upgrade --install $release failed after $n attempts" >&2; return 1; }
    echo ">> [chart] $release attempt $n failed — retrying in 30s (operator webhook not ready?)" >&2
    sleep 30
  done
}

main() {
  [ "$#" -ge 1 ] || { echo "usage: install.sh {crds|deps|health|restart|chart} ..." >&2; return 2; }
  local sub="$1"; shift
  case "$sub" in
    crds)    cmd_crds "$@" ;;
    deps)    cmd_deps "$@" ;;
    health)  cmd_health "$@" ;;
    restart) cmd_restart "$@" ;;
    chart)   cmd_chart "$@" ;;
    *) echo "unknown subcommand: $sub (expected crds|deps|health|restart|chart)" >&2; return 2 ;;
  esac
}

main "$@"
