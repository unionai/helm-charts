#!/usr/bin/env bash
#
# Positive/negative render tests for the dataplane RBAC guards in
# templates/prometheus/{rbac,validate}.yaml and templates/ingress-nginx/validate.yaml.
#
# The snapshot suite only diffs renders that succeed, so it cannot see a guard at all: one
# that stops firing looks identical to one that never existed, and one that starts refusing a
# valid config shows up as a blocked customer deploy rather than a failed test. Both
# directions are asserted here, along with a stable fragment of each refusal -- a guard that
# fires for the wrong reason is still a regression.

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CHART="${SCRIPT_DIR}/../charts/dataplane"

RELEASE="release-name"
NAMESPACE="union"

# Every check below renders the whole chart, and `helm template` refuses outright when a
# dependency named in Chart.yaml is missing from charts/ -- so on a fresh checkout all of them
# fail for that reason rather than on anything they test. Nothing else here vendors: this
# target runs before tests/run.sh, which is the only other thing that does. Keep this ahead of
# the first render, and do not assume a working tree that happens to have charts/ populated
# from an earlier run is evidence the suite is self-sufficient.
#
# `dependency build` is enough on its own -- helm resolves each repository URL straight from
# Chart.yaml, so it needs no `helm repo add`, no `dependency update` and no existing
# Chart.lock.
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
# Asserts the values render. Guards that refuse a working configuration block a deploy.
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
# Asserts the values render AND that kube-state-metrics is actually told to watch what the
# guard concluded it would. Render-success alone is not enough here: the guard's whole job is
# to agree with the Deployment, so a case that passes while the Deployment disagrees is the
# bug, not the pass.
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

# A templated entry is resolved by the subchart against its OWN context, where .Chart and
# .Values differ from ours. Evaluating it here would agree with the Deployment only by
# coincidence -- and where it disagrees the guard waves through a namespace the Role never
# covers. Both cases below resolve to the release namespace in this chart's context, so a
# guard that tried to be clever would accept them.
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

# The other side of that pin: each renders its feature while the permissions half rides on
# the subchart's own Role, which rbac.create: false switches off.
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

# Both keys resolve through `default .Release.Namespace <key>` in their subchart, so one
# naming the release namespace moves nothing -- the workload, its ServiceAccount and the Role
# all stay where rbac.yaml binds them. Refusing it would block an overlay that pins every
# subchart to a common namespace, which is a working configuration and a blocked deploy.
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

# The mismatch the two booleans cannot express. At rbac.scope: true the subchart renders a
# Role in its own namespace and no ClusterRole, while controller.scope.namespace is what
# reaches --watch-namespace -- so any other namespace there is a controller watching what it
# cannot read, silently.
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

echo
if [[ ${failures} -ne 0 ]]; then
  echo "RBAC guard tests: ${failures} of ${checks} checks failed"
  exit 1
fi
echo "RBAC guard tests passed (${checks} checks)"
