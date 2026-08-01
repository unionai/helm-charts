#!/usr/bin/env bash
# Stand up a local k3d dataplane that mirrors the dataplane-integration CI job:
# a single-node k3d cluster with an embedded registry, an in-cluster RustFS object
# store, and the dataplane chart installed with the charts/dataplane/values.k3d.yaml
# overlay. Operator client credentials are inputs (they are NOT baked into any
# committed file); they are written into an ephemeral, 0600, trap-cleaned
# values-provision.yaml — the same shape the CI workflow generates — and passed to
# helm with -f. We deliberately do NOT use `helm --set` for the creds: numeric
# Zitadel client IDs would be coerced to numbers, secrets with , . = break --set
# parsing, and the secret would land on the command line (ps/history).
#
# Usage:
#   hack/k3d/up.sh --client-id <id> --client-secret <secret> \
#     [--cp-host helm-charts-ci.canary.unionai.cloud] \
#     [--org helm-charts-ci] [--cluster-name sm-k3d-dp-1] [--smoke]
#
# Creds may also come from env OPERATOR_CLIENT_ID / OPERATOR_CLIENT_SECRET, or be
# fetched from AWS Secrets Manager with --from-aws-secret <name> (expects JSON
# {client_id, client_secret}); requires awscli + jq.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ── Defaults (match the CI job) ──────────────────────────────────────────────
CLUSTER=sm-k3d-dp-1
CP_HOST=helm-charts-ci.canary.unionai.cloud
ORG=helm-charts-ci
K3D_CLUSTER=ci-dataplane          # the k3d cluster name (docker-level)
UNION_NS=union
RUSTFS_NS=rustfs
RUSTFS_ACCESS_KEY=rustfsadmin
RUSTFS_SECRET_KEY=rustfsadmin
RUSTFS_BUCKET=union-data
CLIENT_ID="${OPERATOR_CLIENT_ID:-}"
CLIENT_SECRET="${OPERATOR_CLIENT_SECRET:-}"
FROM_AWS_SECRET=""
RUN_SMOKE=0

# ── Args ─────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --client-id)        CLIENT_ID="$2"; shift 2 ;;
    --client-secret)    CLIENT_SECRET="$2"; shift 2 ;;
    --cp-host)          CP_HOST="$2"; shift 2 ;;
    --org)              ORG="$2"; shift 2 ;;
    --cluster-name)     CLUSTER="$2"; shift 2 ;;
    --from-aws-secret)  FROM_AWS_SECRET="$2"; shift 2 ;;
    --smoke)            RUN_SMOKE=1; shift ;;
    -h|--help)          sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$FROM_AWS_SECRET" ]; then
  echo ">> fetching operator creds from AWS secret '$FROM_AWS_SECRET'"
  _json="$(aws secretsmanager get-secret-value --secret-id "$FROM_AWS_SECRET" --query SecretString --output text)"
  CLIENT_ID="$(jq -r '.client_id' <<<"$_json")"
  CLIENT_SECRET="$(jq -r '.client_secret' <<<"$_json")"
fi

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: operator client id/secret required (--client-id/--client-secret, env, or --from-aws-secret)." >&2
  exit 2
fi

for bin in k3d kubectl helm docker; do command -v "$bin" >/dev/null || { echo "ERROR: '$bin' not found on PATH." >&2; exit 3; }; done
case "$(helm version --short 2>/dev/null)" in
  v3.*) : ;;
  *) echo "WARN: CI uses helm 3.17.x; other majors may hit the >1MB release-secret limit on this chart." >&2 ;;
esac

# ── Ephemeral creds file (never committed) ───────────────────────────────────
WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT
PROVISION="$WORKDIR/values-provision.yaml"
umask 077
cat > "$PROVISION" <<EOF
# EPHEMERAL — operator credentials; do not commit. Mirrors the values-provision.yaml
# the CI workflow generates from the seeded operator secret.
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

# ── 1. k3d cluster + embedded registry (HTTP mirror on :5000) ────────────────
echo ">> creating k3d cluster '$K3D_CLUSTER' with embedded registry"
cat > "$WORKDIR/k3d-registries.yaml" <<'EOF'
mirrors:
  "k3d-registry:5000":
    endpoint:
      - "http://k3d-registry:5000"
EOF
if ! k3d cluster list 2>/dev/null | grep -q "^$K3D_CLUSTER "; then
  k3d cluster create "$K3D_CLUSTER" \
    --registry-create k3d-registry:0.0.0.0:5001 \
    --registry-config "$WORKDIR/k3d-registries.yaml" \
    --wait --timeout 180s
fi
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# ── 2. CRDs (applied out-of-band, like CI, so they stay out of the release) ──
echo ">> applying dataplane CRDs"
kubectl apply --server-side --force-conflicts -f charts/dataplane/crds/ >/dev/null

# ── 3. Chart dependencies ────────────────────────────────────────────────────
echo ">> building chart dependencies"
for r in "prometheus-community https://prometheus-community.github.io/helm-charts" \
         "fluent https://fluent.github.io/helm-charts" \
         "metrics-server https://kubernetes-sigs.github.io/metrics-server/" \
         "opencost https://opencost.github.io/opencost-helm-chart" \
         "nvidia https://nvidia.github.io/dcgm-exporter/helm-charts" \
         "ingress-nginx https://kubernetes.github.io/ingress-nginx" \
         "unionai https://unionai.github.io/helm-charts"; do
  helm repo add $r >/dev/null 2>&1 || true
done
helm dependency build charts/dataplane >/dev/null 2>&1 \
  || { helm repo update >/dev/null 2>&1; helm dependency update charts/dataplane >/dev/null 2>&1; }

# ── 4. In-cluster RustFS object store + bucket ───────────────────────────────
echo ">> deploying RustFS object store"
kubectl create namespace "$RUSTFS_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$RUSTFS_NS" -f hack/k3d/rustfs.yaml >/dev/null
kubectl wait --for=condition=Available deploy/rustfs -n "$RUSTFS_NS" --timeout=180s
kubectl port-forward -n "$RUSTFS_NS" svc/rustfs 9000:9000 >/dev/null 2>&1 &
PF_PID=$!; trap 'kill $PF_PID 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
sleep 3
if command -v mc >/dev/null; then
  mc alias set k3dstore http://localhost:9000 "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" >/dev/null
  mc mb --ignore-existing "k3dstore/$RUSTFS_BUCKET" >/dev/null
else
  echo "WARN: 'mc' (minio client) not found — create bucket '$RUSTFS_BUCKET' manually if the operator can't." >&2
fi

# ── 5. Install the dataplane chart (base + k3d overlay + creds) ──────────────
echo ">> installing dataplane chart (cluster=$CLUSTER host=$CP_HOST org=$ORG)"
CLUSTER_NAME="$CLUSTER" helm upgrade --install union ./charts/dataplane \
  -f "$PROVISION" \
  -f charts/dataplane/values.k3d.yaml \
  --namespace "$UNION_NS" --create-namespace --take-ownership \
  --wait --timeout 8m || {
    echo "!! install failed — pod diagnostics:" >&2
    kubectl get pods -n "$UNION_NS" -o wide || true
    for p in $(kubectl get pods -n "$UNION_NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1}'); do
      kubectl describe pod -n "$UNION_NS" "$p" 2>&1 | grep -A15 -iE "Events|Warning" || true
      kubectl logs -n "$UNION_NS" "$p" --all-containers --tail=60 2>&1 | tail -60 || true
    done
    exit 1
  }

echo ">> dataplane installed. Waiting for the cluster to register healthy on the CP…"
export CONTROL_PLANE_URL="https://$CP_HOST" CLUSTER_NAME="$CLUSTER" ORG_NAME="$ORG"
python .github/ci-scripts/ci_dataplane.py wait-healthy --timeout 360 || \
  echo "WARN: wait-healthy did not confirm — check operator logs (needs valid creds + CP reachability)."

if [ "$RUN_SMOKE" = "1" ]; then
  echo ">> running smoke suite (--skip-logs, k3d has no log backend)"
  python .github/ci-scripts/ci_dataplane.py setup-routing
  python .github/ci-scripts/ci_dataplane.py run-smoke-suite --skip-logs
fi

echo ">> done. kubeconfig context: k3d-$K3D_CLUSTER   (teardown: hack/k3d/down.sh)"
