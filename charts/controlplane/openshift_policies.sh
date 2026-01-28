#!/bin/bash

set -e

NAMESPACE="${NAMESPACE:-union-cp}"

echo "Applying OpenShift policies for Union Self-Hosted in namespace: $NAMESPACE"

# Ensure the namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "Creating namespace $NAMESPACE..."
    oc create namespace "$NAMESPACE"
fi

# 1. Set Pod Security Standards to privileged to allow:
#    - seLinuxOptions with type "spc_t"
#    - Pods without explicit seccompProfile
echo "Setting Pod Security Standards to privileged..."
oc label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
oc label namespace "$NAMESPACE" pod-security.kubernetes.io/warn=privileged --overwrite
oc label namespace "$NAMESPACE" pod-security.kubernetes.io/audit=privileged --overwrite

# 2. Grant the anyuid SCC to service accounts that need it for seLinuxOptions
echo "Granting anyuid SCC to service accounts..."
oc adm policy add-scc-to-user anyuid -z default -n "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z flyteadmin -n "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z cacheservice -n "$NAMESPACE" 2>/dev/null || true

# 3. Grant privileged SCC for pods that require seLinuxOptions type "spc_t"
echo "Granting privileged SCC to service accounts for seLinuxOptions..."
oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user privileged -z flyteadmin -n "$NAMESPACE" 2>/dev/null || true
oc adm policy add-scc-to-user privileged -z cacheservice -n "$NAMESPACE" 2>/dev/null || true

# # 4. Handle ServiceAccount imagePullSecrets field manager conflicts
# #    The OpenShift "image-registry-pull-secrets_service-account-controller" owns .imagePullSecrets
# #    Delete the ServiceAccounts so Helm can recreate them with its own field manager
# #    NOTE: This must be run immediately before helm install to win the race with OpenShift controller
# echo "Resolving ServiceAccount imagePullSecrets field manager conflicts..."
# echo "  Deleting affected ServiceAccounts (Helm will recreate them)..."
# for sa in flyteadmin cacheservice; do
#     oc delete serviceaccount "$sa" -n "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null &
# done
wait

echo ""
echo "OpenShift policies applied successfully!"
# echo "IMPORTANT: Run 'helm upgrade --install' immediately to avoid race condition with OpenShift controller."
