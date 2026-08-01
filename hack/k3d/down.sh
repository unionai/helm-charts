#!/usr/bin/env bash
# Tear down the local k3d dataplane created by hack/k3d/up.sh.
set -euo pipefail
K3D_CLUSTER="${1:-ci-dataplane}"
if k3d cluster list 2>/dev/null | grep -q "^$K3D_CLUSTER "; then
  echo ">> deleting k3d cluster '$K3D_CLUSTER' (and its embedded registry)"
  k3d cluster delete "$K3D_CLUSTER"
else
  echo ">> k3d cluster '$K3D_CLUSTER' not found — nothing to do"
fi
