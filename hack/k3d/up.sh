#!/usr/bin/env bash
# Stand up a local k3d dataplane that mirrors the dataplane-integration CI job:
# a single-node k3d cluster with an embedded registry, an in-cluster RustFS object
# store, and the dataplane chart installed with charts/dataplane/values.k3d.yaml.
#
# This is the SINGLE SOURCE OF TRUTH for the k3d dataplane setup: the CI workflow
# (.github/workflows/dataplane-integration.yaml) calls the phase sub-commands below
# so its orchestration can't drift from local. CI interleaves its own caching /
# base-image pre-warm between phases; that's why the phases are separately callable.
#
# Phases (idempotent):
#   cluster    create the k3d cluster + embedded HTTP registry
#   storage    deploy RustFS + create the object-store bucket
#   provision  write the ephemeral values-provision.yaml from operator creds
#   install    apply CRDs, build chart deps, helm upgrade --install the dataplane
#   wait       wait for the cluster to register healthy on the control plane
#   all        (default) run every phase in order, then optional --smoke
#
# Usage (local, all phases):
#   hack/k3d/up.sh --client-id <id> --client-secret <secret> [--smoke]
#   hack/k3d/up.sh --from-aws-secret selfmanaged/canary/helm-charts-ci/sm-k3d-dp-1/operator
# Usage (a single phase, e.g. from CI or to iterate locally):
#   hack/k3d/up.sh install
#
# Config comes from env (the names CI already exports) with flag overrides:
#   OPERATOR_CLIENT_ID/SECRET, CP_HOST, ORG_NAME_INPUT, CLUSTER_NAME, UNION_NS,
#   RUSTFS_NS/ACCESS_KEY/SECRET_KEY/BUCKET, K3D_CLUSTER, PROVISION_FILE.
# Creds are written into a 0600 values-provision.yaml and passed to helm with -f
# (never `helm --set`: numeric Zitadel client IDs coerce to numbers, secrets with
# , . = break --set, and --set would put the secret on the command line).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ── Config (env defaults match the CI job; flags override) ───────────────────
CLUSTER="${CLUSTER_NAME:-sm-k3d-dp-1}"
CP_HOST="${CP_HOST:-helm-charts-ci.canary.unionai.cloud}"
ORG="${ORG_NAME_INPUT:-${ORG:-helm-charts-ci}}"
K3D_CLUSTER="${K3D_CLUSTER:-ci-dataplane}"
UNION_NS="${UNION_NS:-union}"
RUSTFS_NS="${RUSTFS_NS:-rustfs}"
RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-rustfsadmin}"
RUSTFS_BUCKET="${RUSTFS_BUCKET:-union-data}"
CLIENT_ID="${OPERATOR_CLIENT_ID:-}"
CLIENT_SECRET="${OPERATOR_CLIENT_SECRET:-}"
# values-provision.yaml must persist across phase invocations (separate CI steps),
# so default to a fixed, gitignored path rather than a temp that a phase would lose.
PROVISION_FILE="${PROVISION_FILE:-$REPO_ROOT/values-provision.yaml}"
FROM_AWS_SECRET=""
RUN_SMOKE=0

PHASE=all
case "${1:-}" in
  cluster|storage|provision|install|wait|all) PHASE="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --client-id)       CLIENT_ID="$2"; shift 2 ;;
    --client-secret)   CLIENT_SECRET="$2"; shift 2 ;;
    --cp-host)         CP_HOST="$2"; shift 2 ;;
    --org)             ORG="$2"; shift 2 ;;
    --cluster-name)    CLUSTER="$2"; shift 2 ;;
    --from-aws-secret) FROM_AWS_SECRET="$2"; shift 2 ;;
    --smoke)           RUN_SMOKE=1; shift ;;
    -h|--help)         sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

_need() { for b in "$@"; do command -v "$b" >/dev/null || { echo "ERROR: '$b' not found on PATH." >&2; exit 3; }; done; }

_resolve_creds() {
  if [ -n "$FROM_AWS_SECRET" ]; then
    _need aws jq
    echo ">> fetching operator creds from AWS secret '$FROM_AWS_SECRET'"
    local j; j="$(aws secretsmanager get-secret-value --secret-id "$FROM_AWS_SECRET" --query SecretString --output text)"
    CLIENT_ID="$(jq -r '.client_id' <<<"$j")"; CLIENT_SECRET="$(jq -r '.client_secret' <<<"$j")"
  fi
  [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || {
    echo "ERROR: operator client id/secret required (--client-id/--client-secret, env OPERATOR_CLIENT_ID/SECRET, or --from-aws-secret)." >&2; exit 2; }
}

# ── Phases ───────────────────────────────────────────────────────────────────
phase_cluster() {
  _need k3d kubectl docker
  echo ">> [cluster] creating k3d cluster '$K3D_CLUSTER' with embedded registry"
  local reg; reg="$(mktemp)"
  cat > "$reg" <<'EOF'
mirrors:
  "k3d-registry:5000":
    endpoint:
      - "http://k3d-registry:5000"
EOF
  # CI pre-loads a pinned k3s image and passes it via K3S_IMAGE to skip a Docker
  # Hub pull; locally it's unset and k3d pulls the default. Retry the create — a
  # transient blip during node bring-up otherwise fails the whole run.
  local img=(); [ -n "${K3S_IMAGE:-}" ] && img=(--image "$K3S_IMAGE")
  if ! k3d cluster list 2>/dev/null | grep -q "^$K3D_CLUSTER "; then
    local n=0
    until k3d cluster create "$K3D_CLUSTER" "${img[@]}" \
        --registry-create k3d-registry:0.0.0.0:5001 \
        --registry-config "$reg" --wait --timeout 180s; do
      n=$((n+1)); [ "$n" -ge 3 ] && { echo "k3d cluster create failed after $n attempts" >&2; rm -f "$reg"; exit 1; }
      echo "cluster create failed (attempt $n) — cleaning up and retrying" >&2
      k3d cluster delete "$K3D_CLUSTER" || true; sleep 10
    done
  fi
  rm -f "$reg"
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
}

phase_storage() {
  _need kubectl
  echo ">> [storage] deploying RustFS + bucket '$RUSTFS_BUCKET'"
  kubectl create namespace "$RUSTFS_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n "$RUSTFS_NS" -f hack/k3d/rustfs.yaml >/dev/null
  kubectl wait --for=condition=Available deploy/rustfs -n "$RUSTFS_NS" --timeout=180s
  kubectl port-forward -n "$RUSTFS_NS" svc/rustfs 9000:9000 >/dev/null 2>&1 &
  local pf=$!; trap 'kill '"$pf"' 2>/dev/null || true' RETURN
  for _ in $(seq 1 20); do curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1 && break; sleep 2; done
  if ! command -v mc >/dev/null; then
    _need curl
    # dl.min.io 504s intermittently on shared runners — retry.
    local n=0
    until [ "$n" -ge 6 ]; do
      curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o "$REPO_ROOT/.mc" && chmod +x "$REPO_ROOT/.mc" && break
      n=$((n+1)); echo "mc download failed (attempt $n) — retrying in $((n*10))s" >&2; sleep $((n*10))
    done
    [ "$n" -ge 6 ] && { echo "mc download failed after $n attempts" >&2; return 1; }
  fi
  local MC; MC="$(command -v mc || echo "$REPO_ROOT/.mc")"
  "$MC" alias set k3dstore http://localhost:9000 "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null
  "$MC" mb --ignore-existing "k3dstore/$RUSTFS_BUCKET" >/dev/null
  echo "bucket-ok"
}

phase_provision() {
  _resolve_creds
  echo ">> [provision] writing $PROVISION_FILE"
  ( umask 077; cat > "$PROVISION_FILE" <<EOF
# EPHEMERAL — operator credentials; do not commit (gitignored). Same shape the CI
# workflow builds from the seeded operator secret.
global:
  AUTH_CLIENT_ID: "$CLIENT_ID"
  CONTROLPLANE_HOST: "$CP_HOST"
  UNION_CONTROL_PLANE_HOST: "$CP_HOST"
  ORG_NAME: "$ORG"
  CLUSTER_NAME: "$CLUSTER"
secrets:
  admin:
    enable: true
    create: true
    clientId: "$CLIENT_ID"
    clientSecret: "$CLIENT_SECRET"
config:
  operator:
    apiKey:
      enabled: true
EOF
  )
}

phase_install() {
  _need kubectl helm
  [ -f "$PROVISION_FILE" ] || { echo "ERROR: $PROVISION_FILE missing — run the 'provision' phase first." >&2; exit 4; }
  case "$(helm version --short 2>/dev/null)" in v3.*) : ;; *) echo "WARN: CI uses helm 3.17.x; other majors may hit helm's 1MB release-secret limit on this chart." >&2 ;; esac
  echo ">> [install] CRDs + deps + helm upgrade --install"
  kubectl apply --server-side --force-conflicts -f charts/dataplane/crds/ >/dev/null
  for r in "prometheus-community https://prometheus-community.github.io/helm-charts" \
           "fluent https://fluent.github.io/helm-charts" \
           "metrics-server https://kubernetes-sigs.github.io/metrics-server/" \
           "opencost https://opencost.github.io/opencost-helm-chart" \
           "nvidia https://nvidia.github.io/dcgm-exporter/helm-charts" \
           "ingress-nginx https://kubernetes.github.io/ingress-nginx" \
           "unionai https://unionai.github.io/helm-charts"; do helm repo add $r >/dev/null 2>&1 || true; done
  if [ -n "$(ls -A charts/dataplane/charts 2>/dev/null)" ]; then helm dependency build charts/dataplane >/dev/null
  else helm repo update >/dev/null 2>&1; helm dependency update charts/dataplane >/dev/null; fi
  CLUSTER_NAME="$CLUSTER" helm upgrade --install union ./charts/dataplane \
    -f "$PROVISION_FILE" -f charts/dataplane/values.k3d.yaml \
    --namespace "$UNION_NS" --create-namespace --take-ownership --wait --timeout 8m && return 0
  local rc=$?
  echo "!! install failed (rc=$rc) — pod diagnostics:" >&2
  kubectl get pods -n "$UNION_NS" -o wide || true
  for p in $(kubectl get pods -n "$UNION_NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1}'); do
    kubectl describe pod -n "$UNION_NS" "$p" 2>&1 | grep -A15 -iE "Events|Warning" || true
    kubectl logs -n "$UNION_NS" "$p" --all-containers --tail=60 2>&1 | tail -60 || true
  done
  return "$rc"
}

phase_wait() {
  echo ">> [wait] waiting for the cluster to register healthy on the control plane"
  CONTROL_PLANE_URL="https://$CP_HOST" CLUSTER_NAME="$CLUSTER" ORG_NAME="$ORG" \
    python .github/ci-scripts/ci_dataplane.py wait-healthy --timeout 360
}

case "$PHASE" in
  cluster)   phase_cluster ;;
  storage)   phase_storage ;;
  provision) phase_provision ;;
  install)   phase_install ;;
  wait)      phase_wait ;;
  all)
    phase_cluster; phase_storage; phase_provision; phase_install; phase_wait
    if [ "$RUN_SMOKE" = 1 ]; then
      echo ">> [smoke] setup-routing + run-smoke-suite --skip-logs"
      CONTROL_PLANE_URL="https://$CP_HOST" CLUSTER_NAME="$CLUSTER" ORG_NAME="$ORG" \
        python .github/ci-scripts/ci_dataplane.py setup-routing
      CONTROL_PLANE_URL="https://$CP_HOST" CLUSTER_NAME="$CLUSTER" ORG_NAME="$ORG" \
        python .github/ci-scripts/ci_dataplane.py run-smoke-suite --skip-logs
    fi
    rm -f "$PROVISION_FILE"
    echo ">> done. kubeconfig context: k3d-$K3D_CLUSTER   (teardown: hack/k3d/down.sh)"
    ;;
esac
