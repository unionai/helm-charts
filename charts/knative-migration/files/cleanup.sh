#!/bin/sh
#
# Cleanup script for the knative-migration Job. Loaded into job.yaml via
# .Files.Get so it stays a plain shell script — lintable with shellcheck,
# no Helm-template escaping issues.
#
# Inputs (env, set by the Job template):
#   NS                - release namespace (where the KnativeServing CR lives)
#   CR                - name of the KnativeServing CR to clean up
#   ADOPTION_ENABLED  - "true" to stamp Helm ownership metadata onto the
#                       12 Knative Serving CRDs left behind by the operator
#                       (required for the helm-install path; harmless and
#                       unnecessary for ArgoCD/Pulumi/etc.)
#   TARGET_RELEASE    - dataplane helm release name (used iff ADOPTION_ENABLED)
#   TARGET_NAMESPACE  - dataplane helm release namespace (used iff ADOPTION_ENABLED)
#
# Design: the operator is assumed to be alive when this Job runs. Deleting
# the KnativeServing CR triggers the operator's finalizer, which removes
# every cluster-scoped and namespace-scoped resource the operator installed
# from its KnativeServing manifest — runtime ClusterRoles, RoleBindings,
# WebhookConfigurations, Deployments, Services, ConfigMaps, HPAs, PDBs.
# CRDs are the exception: knative-operator's Uninstall path explicitly
# filters them out, so we adopt the 12 Knative Serving CRDs here (step 2)
# and delete the 2 operator-binary CRDs (step 3).
set -euo pipefail

# The 12 Knative Serving CRDs the knative-operator installs imperatively
# (no Helm metadata). Canonical source of truth is the dataplane chart's
# charts/dataplane/templates/gateway/crds/ directory; keep this list in
# sync if upstream Knative Serving adds/removes CRDs.
SERVING_CRDS="
certificates.networking.internal.knative.dev
clusterdomainclaims.networking.internal.knative.dev
configurations.serving.knative.dev
domainmappings.serving.knative.dev
images.caching.internal.knative.dev
ingresses.networking.internal.knative.dev
metrics.autoscaling.internal.knative.dev
podautoscalers.autoscaling.internal.knative.dev
revisions.serving.knative.dev
routes.serving.knative.dev
serverlessservices.networking.internal.knative.dev
services.serving.knative.dev
"

# adopt_if_exists stamps Helm release ownership metadata onto a CRD if it
# exists. No-op on a fresh BYOC install where the operator never ran (the
# 12 Serving CRDs don't exist yet — Helm will create them itself during
# the dataplane install). Idempotent via --overwrite; safe to retry.
#
# NotFound is the only `kubectl get` failure treated as "absent". Other
# failures propagate so the Job retries instead of silently skipping
# adoption (which would resurface as an `invalid ownership metadata`
# failure on the subsequent dataplane upgrade).
adopt_if_exists() {
  local crd=$1
  local err
  if err=$(kubectl get crd "$crd" 2>&1 >/dev/null); then
    :
  else
    case "$err" in
      *NotFound*|*"not found"*) return 0 ;;
      *) echo "kubectl get crd $crd failed: $err" >&2; return 1 ;;
    esac
  fi
  kubectl annotate crd "$crd" --overwrite \
    "meta.helm.sh/release-name=$TARGET_RELEASE" \
    "meta.helm.sh/release-namespace=$TARGET_NAMESPACE"
  kubectl label crd "$crd" --overwrite \
    "app.kubernetes.io/managed-by=Helm"
}

# 1. Delete the KnativeServing CR and wait for the operator's finalizer
#    to complete. The operator's reconciler tears down every Deployment,
#    Service, ConfigMap, HPA, PDB, ClusterRole, ClusterRoleBinding, and
#    WebhookConfiguration it installed from the KnativeServing manifest,
#    then removes its own finalizer. `kubectl delete --wait=true` blocks
#    until the API server reaps the CR, which only happens once every
#    finalizer is gone — including the operator's. The 720-second timeout
#    covers the activator pod's 600s terminationGracePeriodSeconds plus
#    margin.
#
#    Failure mode: if the operator is unhealthy or absent at delete time,
#    the operator finalizer never executes and `kubectl delete --wait`
#    blocks until the deadline, then exits non-zero. The Job retries via
#    backoffLimit; if it keeps failing, the operator needs investigation
#    before the migration can proceed. There is no fallback finalizer-strip
#    in this script — proceeding without operator cleanup would leave the
#    runtime RBAC and WebhookConfigurations orphaned, which is exactly what
#    this design avoids.
kubectl delete knativeserving "$CR" -n "$NS" \
  --wait=true --timeout=720s --ignore-not-found

# 2. Adopt the 12 Knative Serving CRDs into the dataplane Helm release.
#    Only meaningful when the dataplane chart is being applied via the
#    Helm CLI (or any wrapper around it): the operator installed these
#    CRDs imperatively with no Helm metadata, so Helm's pre-flight
#    ownership check refuses to apply them on `helm upgrade`. Stamping
#    the metadata here lets the subsequent upgrade proceed. Non-Helm
#    install paths (ArgoCD, Pulumi, kustomize) leave ADOPTION_ENABLED
#    false; this step is then a no-op, avoiding incorrect provenance
#    metadata on resources managed by other tools.
#
#    User-created CRs of these types (e.g. Knative Services in domain
#    namespaces) are preserved: adoption only mutates CRD metadata, and
#    the dataplane chart's subsequent upgrade renders the same CRDs (now
#    Helm-owned) without disturbing instances.
if [ "$ADOPTION_ENABLED" = "true" ]; then
  for crd in $SERVING_CRDS; do
    adopt_if_exists "$crd"
  done
fi

# 3. Delete the two operator-binary CRDs. The operator's finalizer (step 1)
#    does not delete CRDs, and the operator's own bootstrap RBAC + the
#    operator Deployments are pruned by Helm when the knative-operator
#    subchart is disabled in the subsequent dataplane upgrade — but the
#    two operator CRDs may live in a separate subchart (knative-operator-crds)
#    or persist via helm.sh/resource-policy: keep, so delete them
#    explicitly. Fire-and-forget: by this point step 1 has confirmed there
#    are no remaining KnativeServing instances, so the CRDs have nothing
#    to GC.
kubectl delete crd knativeservings.operator.knative.dev --ignore-not-found --wait=false
kubectl delete crd knativeeventings.operator.knative.dev --ignore-not-found --wait=false
