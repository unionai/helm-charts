#!/usr/bin/env bash
#
# Render tests for the dataplane RBAC guards in templates/prometheus/{rbac,validate}.yaml,
# templates/ingress-nginx/validate.yaml and templates/gateway/validate.yaml.
#
# It also covers the values-key combinations no snapshot fixture pins.
#
# The snapshot suite only diffs renders that succeed, so it cannot see a guard at all. Each
# case here asserts either that a guard refuses bad values or that it leaves a working
# configuration alone. Refusals are matched on part of the error text, so a guard firing for
# the wrong reason still fails.

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CHART="${SCRIPT_DIR}/../charts/dataplane"

RELEASE="release-name"
NAMESPACE="union"

# Every check below renders the whole chart, and `helm template` fails outright if a
# dependency named in Chart.yaml is missing from charts/. Nothing else here vendors, so this
# has to stay ahead of the first render. `dependency build` alone is enough: helm reads each
# repository URL from Chart.yaml, so no `helm repo add` or Chart.lock is needed.
echo "Vendoring subchart dependencies..."
helm dependency build "${CHART}"
echo

failures=0
checks=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/helm-charts-rbac-guards.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

# `--set` treats {, } and , as list/kv syntax, so a Go-template namespace entry cannot be
# expressed that way. Write it to a values file instead.
# ksm-namespaces-file <name> <yaml value for namespaces> -> echoes the file path
function ksm-namespaces-file {
  local name=$1
  local value=$2
  local path="${WORK_DIR}/${name}.yaml"
  cat > "${path}" <<EOF
prometheus:
  kube-state-metrics:
    releaseNamespace: false
    namespaces: '${value}'
EOF
  echo "${path}"
}

# Minimum values any dataplane render needs: the control-plane host guard and the admin
# secret. Everything a case is actually testing is passed on top as --set flags.
function render {
  helm template "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    --kube-version 1.32.0 \
    --values "${CHART}/examples/values-test-certs.yaml" \
    --set global.UNION_CONTROL_PLANE_HOST=test-controlplane-host \
    --set secrets.admin.create=false \
    --set secrets.admin.clientSecret=test \
    --set secrets.admin.clientId=test \
    "$@"
}

# expect-render <description> [helm --set flags...]
# Asserts the render succeeds.
function expect-render {
  local desc=$1; shift
  local err
  checks=$((checks + 1))
  if err=$(render "$@" 2>&1 >/dev/null); then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${err}" | head -c 300)"
    failures=$((failures + 1))
  fi
}

# expect-refusal <description> <expected error substring> [helm --set flags...]
# Asserts the values are refused, and refused for the stated reason.
function expect-refusal {
  local desc=$1; shift
  local want=$1; shift
  local err
  checks=$((checks + 1))
  if err=$(render "$@" 2>&1 >/dev/null); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to be refused, but it succeeded"
    failures=$((failures + 1))
  elif [[ "${err}" != *"${want}"* ]]; then
    echo "  FAILED   ${desc}"
    echo "           refused, but not for the expected reason"
    echo "           want substring: ${want}"
    echo "           got: $(grep -o 'Error:.*' <<<"${err}" | head -c 300)"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

# expect-collection-scope <description> <expected --namespaces argument> [helm --set flags...]
# Asserts the render succeeds and that kube-state-metrics is told to watch the namespaces
# the guard accepted. The guard's job is to agree with the Deployment, so checking one
# without the other proves nothing.
function expect-collection-scope {
  local desc=$1; shift
  local want=$1; shift
  local out got
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${out}" | head -c 300)"
    failures=$((failures + 1))
    return
  fi
  got=$(grep -o -- '--namespaces=[^"]*' <<<"${out}" | head -1)
  if [[ "${got}" != "${want}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           guard accepted the values, but kube-state-metrics was told otherwise"
    echo "           want: ${want}"
    echo "           got:  ${got:-<no --namespaces flag: every namespace>}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

# expect-manifest <description> <present|absent> <grep pattern> [helm --set flags...]
# Asserts the render succeeds and that a manifest is or is not in the output. For gates that
# are a plain conditional rather than a refusal, where nothing errors either way.
function expect-manifest {
  local desc=$1; shift
  local want=$1; shift
  local pattern=$1; shift
  local out
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${out}" | head -c 300)"
    failures=$((failures + 1))
    return
  fi
  if grep -q -- "${pattern}" <<<"${out}"; then
    if [[ "${want}" == "present" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected '${pattern}' to be absent from the render, but it is there"
      failures=$((failures + 1))
    fi
  else
    if [[ "${want}" == "absent" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected '${pattern}' in the render, but it is missing"
      failures=$((failures + 1))
    fi
  fi
}

echo "Running RBAC guard tests..."

echo "- supported configurations still render"
expect-render "chart defaults"
expect-render "full-privilege overlay" \
  --set low_privilege=false \
  --set prometheus.kube-state-metrics.releaseNamespace=false \
  --set 'prometheus.kube-state-metrics.collectors={pods,deployments,daemonsets,resourcequotas,nodes,namespaces}'
expect-render "explicit prometheus + kube-state-metrics ServiceAccount names" \
  --set prometheus.serviceAccounts.server.create=false \
  --set prometheus.serviceAccounts.server.name=supplied-prometheus \
  --set prometheus.kube-state-metrics.serviceAccount.create=false \
  --set prometheus.kube-state-metrics.serviceAccount.name=supplied-ksm

echo "- kube-state-metrics collection scope resolves, rather than being matched literally"
expect-collection-scope "chart defaults bind the release namespace" \
  "--namespaces=${NAMESPACE}"
expect-collection-scope "namespaces names the release namespace, releaseNamespace off" \
  "--namespaces=${NAMESPACE}" \
  --set prometheus.kube-state-metrics.releaseNamespace=false \
  --set "prometheus.kube-state-metrics.namespaces=${NAMESPACE}"
expect-collection-scope "namespaces list names the release namespace, deduped against releaseNamespace" \
  "--namespaces=${NAMESPACE}" \
  --set "prometheus.kube-state-metrics.namespaces={${NAMESPACE}}"
expect-refusal "no namespace bound at all, which the subchart reads as every namespace" \
  "must collect from the release namespace" \
  --set prometheus.kube-state-metrics.releaseNamespace=false
expect-refusal "a namespace the Role does not cover" \
  "must collect from the release namespace" \
  --set prometheus.kube-state-metrics.namespaces=other
expect-refusal "the release namespace plus another" \
  "must collect from the release namespace" \
  --set "prometheus.kube-state-metrics.namespaces=other\,${NAMESPACE}"

# The subchart resolves a templated entry against its own context, where .Chart and .Values
# differ from ours, so the guard cannot evaluate it and refuses instead. Both cases below
# resolve to the release namespace in this chart's context, so a guard that tried would
# accept them.
echo "- templated collection scope is refused rather than guessed at"
expect-refusal "a templated entry that resolves differently in the subchart" \
  "is templated, which is not supported" \
  --values "$(ksm-namespaces-file chart-name '{{ .Chart.Name }}')"
expect-refusal "a templated entry, even one that would resolve correctly here" \
  "is templated, which is not supported" \
  --values "$(ksm-namespaces-file release-ns '{{ .Release.Namespace }}')"

echo "- collectors stay in step with the grant"
expect-refusal "a collector with no rule mapped for it" \
  "has no rule for" \
  --set 'prometheus.kube-state-metrics.collectors={pods,secrets}'
expect-refusal "a cluster-scoped collector under low_privilege" \
  "cluster-scoped and cannot be granted" \
  --set 'prometheus.kube-state-metrics.collectors={pods,nodes}'
expect-refusal "an empty collector list, which the subchart reads as all 28" \
  "must name at least one collector" \
  --set prometheus.kube-state-metrics.collectors=null

echo "- subchart-native RBAC stays off, so low_privilege keeps governing it"
expect-refusal "prometheus.rbac.create" \
  "prometheus.rbac.create must stay false" \
  --set prometheus.rbac.create=true
expect-refusal "prometheus.kube-state-metrics.rbac.create" \
  "kube-state-metrics.rbac.create must stay false" \
  --set prometheus.kube-state-metrics.rbac.create=true

# Each of these features gets its permissions from the subchart's own Role, which
# rbac.create: false switches off.
echo "- kube-state-metrics features the chart-owned grant cannot serve are refused"
expect-refusal "kubeRBACProxy, which needs review creates and breaks the scrape job" \
  "kubeRBACProxy.enabled must stay false" \
  --set prometheus.kube-state-metrics.kubeRBACProxy.enabled=true
expect-refusal "customResourceState, whose CRD reads ride on rbac.extraRules" \
  "customResourceState.enabled must stay false" \
  --set prometheus.kube-state-metrics.customResourceState.enabled=true
expect-refusal "autosharding, which needs pod and statefulset reads" \
  "autosharding.enabled must stay false" \
  --set prometheus.kube-state-metrics.autosharding.enabled=true
expect-refusal "rbac.extraRules, which is dropped without a word" \
  "rbac.extraRules renders only inside" \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].apiGroups={""}' \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].resources={secrets}' \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].verbs={get}'

echo "- bindings cannot be pointed at a ServiceAccount or namespace nothing runs as"
expect-refusal "prometheus ServiceAccount creation off with no name supplied" \
  "serviceAccounts.server.create: false needs" \
  --set prometheus.serviceAccounts.server.create=false
expect-refusal "kube-state-metrics ServiceAccount creation off with no name supplied" \
  "serviceAccount.create: false needs" \
  --set prometheus.kube-state-metrics.serviceAccount.create=false
expect-refusal "prometheus.server.fullnameOverride cleared without a name" \
  "fullnameOverride must stay set" \
  --set prometheus.server.fullnameOverride=""
expect-refusal "prometheus.forceNamespace naming another namespace" \
  "prometheus.forceNamespace is \"elsewhere\"" \
  --set prometheus.forceNamespace=elsewhere
expect-refusal "kube-state-metrics.namespaceOverride naming another namespace" \
  "namespaceOverride is \"elsewhere\"" \
  --set prometheus.kube-state-metrics.namespaceOverride=elsewhere

# Both keys resolve through `default .Release.Namespace <key>` in their subchart, so naming
# the release namespace moves nothing: the workload, its ServiceAccount and the Role all stay
# where rbac.yaml binds them. Refusing it would block an overlay that pins every subchart to
# one namespace, which works fine.
expect-render "prometheus.forceNamespace naming the release namespace" \
  --set "prometheus.forceNamespace=${NAMESPACE}"
expect-render "kube-state-metrics.namespaceOverride naming the release namespace" \
  --set "prometheus.kube-state-metrics.namespaceOverride=${NAMESPACE}"

echo "- values that are inert do not block a deploy"
expect-render "kube-state-metrics off, stale rbac.create left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.rbac.create=true
expect-render "kube-state-metrics off, stale collector override left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set 'prometheus.kube-state-metrics.collectors={pods,secrets}'
expect-render "kube-state-metrics off, stale collection scope left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.releaseNamespace=false
expect-render "kube-state-metrics off, stale templated collection scope left behind" \
  --values "$(ksm-namespaces-file disabled-tpl '{{ .Chart.Name }}')" \
  --set prometheus.kube-state-metrics.enabled=false
expect-render "kube-state-metrics off, stale empty collector list left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.collectors=null
expect-render "kube-state-metrics off, stale serviceAccount.create left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.serviceAccount.create=false
expect-render "kube-state-metrics off, stale namespaceOverride left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.namespaceOverride=elsewhere
expect-render "kube-state-metrics off, stale kubeRBACProxy left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.kubeRBACProxy.enabled=true
expect-render "kube-state-metrics off, stale autosharding left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.autosharding.enabled=true
expect-render "kube-state-metrics off, stale customResourceState left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set prometheus.kube-state-metrics.customResourceState.enabled=true
expect-render "kube-state-metrics off, stale rbac.extraRules left behind" \
  --set prometheus.kube-state-metrics.enabled=false \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].apiGroups={""}' \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].resources={secrets}' \
  --set 'prometheus.kube-state-metrics.rbac.extraRules[0].verbs={get}'

echo "- ingress-nginx scope and RBAC ownership move together"
expect-refusal "controller scoped while the subchart's own RBAC stays cluster-wide" \
  "controller.scope.enabled is true but" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.rbac.scope=false \
  --set ingress-nginx.controller.scope.enabled=true
expect-render "same mismatch, but the subchart renders no controller RBAC to mismatch" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.rbac.create=false \
  --set ingress-nginx.rbac.scope=false \
  --set ingress-nginx.controller.scope.enabled=true
expect-render "both scoped (chart default)" \
  --set ingress-nginx.enabled=true
expect-render "both unscoped, to serve an Ingress from another namespace" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.rbac.scope=false \
  --set ingress-nginx.controller.scope.enabled=false

# At rbac.scope: true the subchart renders a Role in its own namespace and no ClusterRole,
# while controller.scope.namespace is what reaches --watch-namespace. Any other namespace
# there is a controller silently watching what it cannot read.
expect-refusal "scoped RBAC watching a namespace the Role does not cover" \
  "controller.scope.namespace is \"elsewhere\"" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.controller.scope.namespace=elsewhere
expect-render "scoped RBAC watching the namespace the Role is in" \
  --set ingress-nginx.enabled=true \
  --set "ingress-nginx.controller.scope.namespace=${NAMESPACE}"
expect-render "watch namespace set but both scopes off, so it never reaches --watch-namespace" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.rbac.scope=false \
  --set ingress-nginx.controller.scope.enabled=false \
  --set ingress-nginx.controller.scope.namespace=elsewhere
expect-render "watch namespace set but the subchart renders no controller RBAC" \
  --set ingress-nginx.enabled=true \
  --set ingress-nginx.rbac.create=false \
  --set ingress-nginx.controller.scope.namespace=elsewhere

# The vendored Knative Serving / Kourier stack under templates/gateway/ holds cluster-scoped
# RBAC with no namespaced form, so app serving requires low_privilege: false. The snapshot
# suite covers the rendering; the refusal, and what still renders after it, are asserted here.
echo "- app serving and low_privilege are refused together, not silently reconciled"
# knative-operator must be disabled alongside zero_trust (Helm evaluates that subchart
# condition at parse time), and orgName is what the Envoy auth filter is keyed on.
zt=(--set zero_trust.enabled=true --set knative-operator.enabled=false --set orgName=test-org)
expect-manifest "the stack renders with apps on and low_privilege off" present "name: knative-serving-core" \
  "${zt[@]}" --set apps.enabled=true --set low_privilege=false
expect-manifest "and its Kourier half with it" present "name: net-kourier" \
  "${zt[@]}" --set apps.enabled=true --set low_privilege=false
expect-refusal "apps on at the low_privilege default" \
  "requires low_privilege: false" \
  "${zt[@]}" --set apps.enabled=true

# App serving is off by default, so a zero-trust deploy that sets nothing else renders.
expect-manifest "the default zero-trust install renders, with no Knative stack" \
  absent "name: knative-serving-core" "${zt[@]}"

# The Envoy gateway gates on zero_trust.enabled alone and holds no cluster-scoped RBAC, so
# dropping app serving leaves the zero-trust dataplane and its routes intact.
expect-manifest "and keeps the Envoy gateway" \
  present "union-operator-gateway-envoy-bootstrap" "${zt[@]}"

# The deprecated serving.enabled still reaches app serving; values.yaml leaves apps.enabled
# null so it keeps deciding.
expect-manifest "the deprecated serving.enabled still turns app serving on" \
  present "name: knative-serving-core" \
  "${zt[@]}" --set serving.enabled=true --set low_privilege=false
expect-manifest "and an explicit apps.enabled still overrides it" absent "name: knative-serving-core" \
  "${zt[@]}" --set serving.enabled=true --set apps.enabled=false --set low_privilege=false

# low_privilege decides privilege scope, namespaces.enabled decides whether work namespaces
# are pre-seeded, and commonServiceAccount.enabled decides identity sharing. The snapshot
# fixtures pin the combinations a deployment uses; these pin that the three axes are actually
# independent, including the combinations no fixture covers.
echo "- the privilege, namespace and identity axes are independent"
# These assert on `kind: Namespace`, not on the retention annotation. Asserting the annotation
# is absent cannot tell "no Namespace rendered" from "a Namespace rendered unprotected", and
# the second is the state worth catching.
expect-manifest "namespaces.enabled pre-seeds at full privilege" \
  present "kind: Namespace" \
  --set low_privilege=false --set namespaces.enabled=true
expect-manifest "and namespaces.enabled: false leaves the Namespace objects to someone else" \
  absent "kind: Namespace" \
  --set low_privilege=false --set namespaces.enabled=false
expect-manifest "low_privilege still suppresses pre-seeding, whatever namespaces.enabled says" \
  absent "kind: Namespace" \
  --set namespaces.enabled=true

# namespaces.labels / namespaces.annotations are the only hook for Namespace metadata the
# chart creates, so they carry the retention policy an operator's deployment tool needs.
expect-manifest "pre-seeded namespaces carry the default Helm retention policy" \
  present "helm.sh/resource-policy: keep" \
  --set low_privilege=false --set namespaces.enabled=true
expect-manifest "operator annotations merge with it rather than replacing it" \
  present "argocd.argoproj.io/sync-options: Prune=false" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.argocd\.argoproj\.io/sync-options=Prune=false'
expect-manifest "and the Helm default survives that merge" \
  present "helm.sh/resource-policy: keep" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.argocd\.argoproj\.io/sync-options=Prune=false'
expect-manifest "nulling the default drops it, for tooling that owns the lifecycle" \
  absent "helm.sh/resource-policy: keep" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.helm\.sh/resource-policy=null'
expect-manifest "namespaces.labels lands on the pre-seeded namespaces" \
  present "pod-security.kubernetes.io/enforce: baseline" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.labels.pod-security\.kubernetes\.io/enforce=baseline'
expect-manifest "a custom namespaces.static list replaces the defaults" \
  present "name: my-only-namespace" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.static={my-only-namespace}'
expect-manifest "and the hardcoded six are gone with it" \
  absent "name: flytesnacks-development" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.static={my-only-namespace}'

# The bug this replaces: namespaces.enabled defaults false, so `or (not namespaces.enabled)
# low_privilege` made a default full-privilege install look single-namespace and gated off the
# component that creates namespaces for newly registered projects.
expect-manifest "clusterresourcesync renders at full privilege with namespaces.enabled unset" \
  present "name: union-syncresources" \
  --set low_privilege=false --set clusterresourcesync.enabled=true
expect-manifest "and is still suppressed under low_privilege, where nothing needs it" \
  absent "name: union-syncresources" \
  --set clusterresourcesync.enabled=true

expect-manifest "commonServiceAccount.enabled: false is honored under low_privilege" \
  present "serviceAccountName: operator-system" \
  --set commonServiceAccount.enabled=false
expect-manifest "and the shared identity is still the default there" \
  absent "serviceAccountName: operator-system"

# The per-component names are what an operator builds cloud workload-identity bindings
# from, so pin the two the values.yaml comment calls out specially: buildkit is enabled
# by default and moves, and fluentbit does not.
expect-manifest "buildkit moves to its own identity with the rest" \
  present 'serviceAccountName: "union-imagebuilder"' \
  --set commonServiceAccount.enabled=false
# fluentbit's account name comes from the subchart key fluentbit.serviceAccount.name,
# pinned to union-system here, and that pin beats the per-component fallback. Partitioning
# it needs an explicit name override -- see the commonServiceAccount comment in values.yaml.
expect-manifest "fluentbit stays on the shared name until told otherwise" \
  present "serviceAccountName: union-system" \
  --set commonServiceAccount.enabled=false
expect-manifest "and an explicit name override partitions it" \
  present "serviceAccountName: fluentbit-system" \
  --set commonServiceAccount.enabled=false \
  --set fluentbit.serviceAccount.name=fluentbit-system

echo
if [[ ${failures} -ne 0 ]]; then
  echo "RBAC guard tests: ${failures} of ${checks} checks failed"
  exit 1
fi
echo "RBAC guard tests passed (${checks} checks)"
