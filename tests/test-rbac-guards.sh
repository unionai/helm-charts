#!/usr/bin/env bash
#
# Render tests for the dataplane RBAC guards in templates/prometheus/{rbac,validate}.yaml,
# templates/ingress-nginx/validate.yaml, templates/gateway/validate.yaml and
# templates/common/rbac.yaml.
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

# expect-binding-subject <description> <binding kind> <binding name> <expected subjects>
#   [helm --set flags...]
# Asserts the render succeeds and that a named RoleBinding/ClusterRoleBinding binds exactly
# the identities given, in order, as a comma-separated list. expect-manifest cannot do this:
# the per-component name also appears on the Deployment, so a plain grep passes even when the
# binding still names the shared account.
#
# The whole list matters, not just the first entry: a pooled slot's role is bound to every
# ServiceAccount that declared into it, so the subject list is what says pooling happened --
# and, when the identities are shared, that the emitter deduplicated them.
function expect-binding-subject {
  local desc=$1; shift
  local kind=$1; shift
  local name=$1; shift
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
  # Slice the one document whose kind and metadata.name both match, then read every
  # ServiceAccount subject name out of it, in order.
  # A pooled role can be bound in several namespaces at once, so stop at the end of the
  # first matching document rather than accumulating every copy's subjects.
  got=$(awk -v kind="kind: ${kind}" -v name="  name: ${name}" '
    $0 == "---" {
      if (done) { finished = 1 }
      inmatch = 0; sawkind = 0; sawname = 0; insubjects = 0
    }
    $0 == kind { sawkind = 1 }
    $0 == name && !insubjects { sawname = 1 }
    $0 == "subjects:" {
      insubjects = 1
      if (sawkind && sawname && !finished) { inmatch = 1; done = 1 }
    }
    inmatch && /^  - kind: ServiceAccount$/ {
      getline; sub(/^ *name: /, "")
      out = out == "" ? $0 : out "," $0
    }
    END { print out }
  ' <<<"${out}")
  if [[ "${got}" != "${want}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           ${kind}/${name} binds the wrong identities"
    echo "           want: ${want}"
    echo "           got:  ${got:-<no matching binding in the render>}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

# expect-binding-namespaces <description> <binding kind> <binding name> <expected namespaces>
#   [helm --set flags...]
# Asserts the render succeeds and that every binding of that kind and name lands in exactly
# the namespaces given -- comma-separated, sorted, empty string for "no such binding".
#
# Where a binding is, not just what it says, is the whole point of the work-ns slot: the role
# is a ClusterRole so its rules are written once, and it is confined by being referenced only
# from namespaced RoleBindings. A grep cannot tell "bound in the work namespaces" from "bound
# in the release namespace too", and that difference is exactly what the split buys.
function expect-binding-namespaces {
  local desc=$1; shift
  local kind=$1; shift
  local name=$1; shift
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
  # metadata.name precedes metadata.namespace, and roleRef carries no namespace, so the
  # first `namespace:` after a matching kind and name is the object's own.
  got=$(awk -v kind="kind: ${kind}" -v name="  name: ${name}" '
    $0 == "---" { sawkind = 0; sawname = 0; emitted = 0 }
    $0 == kind { sawkind = 1 }
    $0 == name { sawname = 1 }
    sawkind && sawname && !emitted && /^  namespace: / {
      sub(/^  namespace: /, ""); print; emitted = 1
    }
  ' <<<"${out}" | sort -u | paste -sd, -)
  if [[ "${got}" != "${want}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           ${kind}/${name} is bound in the wrong namespaces"
    echo "           want: ${want:-<nowhere>}"
    echo "           got:  ${got:-<nowhere>}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

# expect-role-resource <description> <present|absent> <role name> <resource> [helm --set flags...]
# Asserts the render succeeds and that a resource is or is not listed in the rules of one
# named role.
#
# A plain grep cannot do this. Several subcharts grant `nodes`, so searching the whole render
# for it passes no matter which role carries it -- including when the role under test has
# none. Scoping to the one document is what makes the assertion mean anything.
function expect-role-resource {
  local desc=$1; shift
  local want=$1; shift
  local role=$1; shift
  local resource=$1; shift
  local out doc
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${out}" | head -c 300)"
    failures=$((failures + 1))
    return
  fi
  # Buffer each document and emit only the one whose metadata.name matches. A binding names
  # the role too, under roleRef, so restrict to documents that carry a rules block.
  doc=$(awk -v name="  name: ${role}" '
    $0 == "---" { if (sawname && sawrules) print buf; buf = ""; sawname = 0; sawrules = 0; next }
    { buf = buf $0 "\n" }
    $0 == name { sawname = 1 }
    $0 == "rules:" { sawrules = 1 }
    END { if (sawname && sawrules) print buf }
  ' <<<"${out}")
  if [[ -z "${doc}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           no role named ${role} with a rules block is in the render"
    failures=$((failures + 1))
    return
  fi
  if grep -qE "^ +- ${resource}\$" <<<"${doc}"; then
    if [[ "${want}" == "present" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected ${role} not to grant ${resource}, but it does"
      failures=$((failures + 1))
    fi
  else
    if [[ "${want}" == "absent" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected ${role} to grant ${resource}, but it does not"
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

# The kube-prometheus-stack subchart owns its own RBAC and no template in this chart reaches
# it, so low_privilege has to leave it alone. That used to be pinned by a second 12.5k-line
# monitoring golden that differed from the first only by the generic privilege delta; these
# two checks assert the same negative against both privilege modes for three lines.
echo "- low_privilege does not reach the kube-prometheus-stack subchart's RBAC"
expect-manifest "the subchart's prometheus ClusterRole is there under low_privilege" \
  present "name: monitoring-prometheus" \
  --set monitoring.enabled=true --set clusterresourcesync.enabled=true
expect-manifest "and is unchanged at full privilege" \
  present "name: monitoring-prometheus" \
  --set monitoring.enabled=true --set clusterresourcesync.enabled=true \
  --set low_privilege=false

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

# The identity axis is independent of the privilege axis, so the per-component name has to
# survive the switch to low_privilege: false. The slot emitter builds every subject list from
# one component registry, so the risk is no longer per-template drift -- it is that pooling
# and identity get wired to each other. These pin that they are not: the pooled role's
# subject list follows commonServiceAccount.enabled on both sides of the privilege switch,
# and the per-component cluster roles do the same.
expect-binding-subject "the pooled work-ns role binds every declarer at low privilege" \
  RoleBinding union-work-ns leaseworker,operator-system,proxy-system \
  --set commonServiceAccount.enabled=false
expect-binding-subject "and collapses to one subject when they share an identity" \
  RoleBinding union-work-ns union-system
expect-binding-subject "a per-component cluster role binds the per-component identity" \
  ClusterRoleBinding union-operator-work-ns-cluster-read operator-system \
  --set commonServiceAccount.enabled=false --set low_privilege=false
expect-binding-subject "and the shared identity reaches it by default" \
  ClusterRoleBinding union-operator-work-ns-cluster-read union-system \
  --set low_privilege=false

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
echo "- the work-ns role reaches work namespaces and nowhere else"

# The security claim of the slot split, stated as a location: under full privilege the pooled
# work-ns role is never bound where union's own Deployments and Secrets live. Under low
# privilege the release namespace *is* the work namespace, so it is bound there on purpose.
expect-binding-namespaces "work-ns binds only the listed work namespaces at full privilege" \
  RoleBinding union-work-ns flytesnacks-development,flytesnacks-staging \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.static={flytesnacks-development,flytesnacks-staging}'
# No static list means no namespace is known at render time, so the chart emits no binding
# at all and whatever provisions the namespaces owes each one. That the chart stays out of it
# is only half the claim; the provisioner section below pins the other half.
expect-binding-namespaces "and binds nowhere when no work namespace is known at render time" \
  RoleBinding union-work-ns "" \
  --set low_privilege=false
expect-binding-namespaces "under low_privilege it binds the release namespace, which is the work namespace" \
  RoleBinding union-work-ns union

# work-ns-cluster-read exists because a caller that lists with an empty namespace is
# authorized as a cluster-scope check. Under low_privilege those caches are namespace-scoped
# and the pooled Role already covers them, so the slot emits nothing at all.
expect-manifest "work-ns-cluster-read is emitted at full privilege" \
  present "name: union-operator-work-ns-cluster-read" \
  --set low_privilege=false
expect-manifest "and not at all under low_privilege" \
  absent "name: union-operator-work-ns-cluster-read"

# Nodes are cluster-scoped, so this slot is the only one that can carry them: a RoleBinding
# grants nothing cluster-scoped whatever role it points at. The informer runs under two of the
# four billing models, so the grant is gated the same way -- and withheld under the other two,
# which is the narrowing the slot exists for.
expect-role-resource "the node informer's grant appears under Legacy billing" \
  present union-operator-work-ns-cluster-read nodes \
  --set low_privilege=false --set config.operator.billing.model=Legacy
expect-role-resource "and under Shadow billing" \
  present union-operator-work-ns-cluster-read nodes \
  --set low_privilege=false --set config.operator.billing.model=Shadow
expect-role-resource "and not under the default ResourceUsage billing" \
  absent union-operator-work-ns-cluster-read nodes \
  --set low_privilege=false
# The operator reaches the same decision from a tpl'd value and a lower-cased one -- the
# config passes through tpl and its enum parser retries lower-cased -- so a gate comparing
# the raw string would withhold the grant while the informer starts. That direction fails
# closed at the API server, not at render.
expect-role-resource "and follows a lower-cased model, which the operator also accepts" \
  present union-operator-work-ns-cluster-read nodes \
  --set low_privilege=false --set config.operator.billing.model=legacy
# disableClusterPermissions stops the informer outright, so the grant goes with it.
expect-role-resource "and is withheld when cluster permissions are disabled outright" \
  absent union-operator-work-ns-cluster-read nodes \
  --set low_privilege=false --set config.operator.billing.model=Legacy \
  --set config.operator.disableClusterPermissions=true

# comp-ns-write is empty at stock values -- both its declaring features are off by default --
# so no snapshot fixture renders it. Turning one on is the only way to see the slot at all.
expect-manifest "comp-ns-write appears once a component declares into it" \
  present "name: union-comp-ns-write" \
  --set config.operator.secretsWatcher.enabled=true
expect-manifest "and is absent at stock values, where nothing declares" \
  absent "name: union-comp-ns-write"

echo
echo "- the runtime provisioner supplies the work-ns binding the chart cannot"

# Where work namespaces are created at runtime the chart binds nothing itself, so
# clusterresourcesync has to. Three grants must appear together: the RoleBinding it is told to
# create per namespace, ordinary authority to create a RoleBinding at all, and the `bind`
# grant without which the API server refuses to let it reference a role it does not hold.
# Any one missing leaves a full-privilege install whose work namespaces are unreachable, and
# no snapshot of the release namespace alone would show it.
expect-manifest "the work-ns RoleBinding is handed to the provisioner at full privilege" \
  present "ab_work_ns_binding.yaml" \
  --set low_privilege=false --set clusterresourcesync.enabled=true
expect-role-resource "and the bind grant that lets it reference the pooled role" \
  present union-clustersync-resource clusterroles \
  --set low_privilege=false --set clusterresourcesync.enabled=true
# expect-role-resource matches a line anywhere in the role, so this pins the resourceNames
# entry rather than the verb: a bind grant that lost its resourceNames, or aimed at another
# role, would stop naming union-work-ns here.
expect-role-resource "confined by resourceNames to the one chart-authored role" \
  present union-clustersync-resource union-work-ns \
  --set low_privilege=false --set clusterresourcesync.enabled=true
# clusterRoleRules is an operator override, so the ordinary rolebindings authority is emitted
# from the template too. Withdrawing it would fail silently: clean render, refused sync.
expect-role-resource "and ordinary rolebindings authority survives an emptied override" \
  present union-clustersync-resource rolebindings \
  --set low_privilege=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules=null'

# namespaces.static is a pre-seeded SUBSET, not the complement of runtime provisioning:
# clusterresourcesync still creates a namespace per project as projects are registered. So
# both halves stay in this posture too. Suppressing them here is the bug that leaves every
# namespace registered after install unreachable.
expect-manifest "and both are still handed over when the chart also pre-seeds namespaces" \
  present "ab_work_ns_binding.yaml" \
  --set low_privilege=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-role-resource "with the bind grant kept in the same posture" \
  present union-clustersync-resource clusterroles \
  --set low_privilege=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

echo
echo "- leaseworker and flytepropeller declare into slots instead of owning roles"

# Both components' hand-written roles are gone. union-leaseworker cannot be checked with a
# grep: a PriorityClass of that name still ships, so the name is in the render either way.
# What must be absent is the cluster-wide ClusterRoleBinding it used to carry.
expect-binding-subject "the cluster-wide union-leaseworker ClusterRoleBinding is gone" \
  ClusterRoleBinding union-leaseworker "" \
  --set low_privilege=false
expect-manifest "and flytepropeller-role with it" \
  absent "name: flytepropeller-role" \
  --set low_privilege=false --set flytepropeller.enabled=true

# Their wildcards now live in the pooled role, bound per work namespace rather than
# cluster-wide. The subject list is registry order, and it is what says both components
# joined the pool rather than keeping a role of their own.
expect-binding-subject "both join the pooled work-ns role, in registry order" \
  RoleBinding union-work-ns leaseworker,operator-system,proxy-system,flytepropeller-system \
  --set commonServiceAccount.enabled=false --set flytepropeller.enabled=true
# Disabling a component drops it from the pool, which is what makes the pooled role track
# the components actually installed rather than everything the chart can install.
# That its `*` resource wildcard goes with it is pinned by the
# dataplane.no-wildcard-components snapshot instead: expect-role-resource greps the whole
# role document, so it cannot tell a wildcard under `resources` from one under `apiGroups`,
# and operator declares the latter in this slot either way.
expect-binding-subject "and drop out of it when disabled" \
  RoleBinding union-work-ns operator-system,proxy-system \
  --set commonServiceAccount.enabled=false \
  --set leaseworker.enabled=false --set flytepropeller.enabled=false

echo
echo "- the secrets watcher stays inside the namespaces it is granted"

# The watcher finds what to restart by listing pods carrying platform.union.ai/zone, and only
# union's own components carry it: the dataplane's, in the release namespace, and the control
# plane's, in its own namespace when the two share a cluster. Left unconfigured it lists every
# namespace instead -- a cluster-scope check no RoleBinding satisfies -- and the first Get in a
# namespace it holds nothing in ends the process. So the chart names the namespaces itself.
expect-manifest "the watch list is the release namespace alone by default" \
  present "          - union\$" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false
expect-manifest "and picks up the control plane namespace when one is set" \
  present "          - union-cp\$" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set controlplaneNamespace=union-cp
expect-manifest "an explicit namespaces list wins over the default" \
  absent "          - union-cp\$" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set controlplaneNamespace=union-cp \
  --set 'config.operator.secretsWatcher.namespaces={somewhere-else}'
# ...and the grants follow it, in both directions. Config and RBAC read one define precisely
# so this cannot drift: a namespace granted but not watched is an overgrant, and one watched
# but not granted is a Forbidden the watcher dies on.
expect-binding-namespaces "and the grants follow the explicit list rather than controlplaneNamespace" \
  RoleBinding operator-system-secrets-watcher somewhere-else \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set controlplaneNamespace=union-cp \
  --set 'config.operator.secretsWatcher.namespaces={somewhere-else}'
# An explicitly empty list is the operator's way of asking for every namespace, so it must
# survive as an empty list rather than being overwritten by the default -- and must not be
# emitted twice, which a duplicate key would resolve silently in favour of the later one.
expect-manifest "an explicitly empty list stays empty" \
  present "        namespaces: \[\]" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set 'config.operator.secretsWatcher.namespaces=null'
expect-manifest "and is not emitted twice" \
  absent "          - union\$" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set 'config.operator.secretsWatcher.namespaces=null'

# The control plane half is a Role in someone else's namespace, so the slot emitter cannot
# carry it. It was previously gated on low_privilege, which left the watcher listing control
# plane pods at full privilege with no grant to read them.
expect-binding-namespaces "the control plane Role is bound in the control plane namespace at full privilege" \
  RoleBinding operator-system-secrets-watcher union-cp \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false \
  --set controlplaneNamespace=union-cp
expect-binding-namespaces "and still under low_privilege" \
  RoleBinding operator-system-secrets-watcher union-cp \
  --set config.operator.secretsWatcher.enabled=true \
  --set controlplaneNamespace=union-cp
expect-manifest "and nothing is emitted when the control plane is elsewhere" \
  absent "name: operator-system-secrets-watcher" \
  --set config.operator.secretsWatcher.enabled=true --set low_privilege=false

echo
echo "- namespaces.static and the release namespace"

# Listing the release namespace as a work namespace would bind work-ns where union's own
# components run, undoing the split above with nothing in the render to show it.
expect-refusal "listing the release namespace in namespaces.static is refused" \
  "must not contain the release namespace" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.static={union,flytesnacks-development}'
expect-refusal "an empty namespaces.static with namespaces.enabled is refused" \
  "requires a non-empty namespaces.static" \
  --set low_privilege=false --set namespaces.enabled=true \
  --set 'namespaces.static=null'

# Both guards read namespaces.static, which low_privilege ignores entirely. Firing there
# would report a fault that is not one: work-ns is bound in the release namespace in that
# mode by design.
expect-render "neither guard fires under low_privilege, where namespaces.static is ignored" \
  --set namespaces.enabled=true \
  --set 'namespaces.static={union}'
expect-render "including with an empty list" \
  --set namespaces.enabled=true \
  --set 'namespaces.static=null'

echo
if [[ ${failures} -ne 0 ]]; then
  echo "RBAC guard tests: ${failures} of ${checks} checks failed"
  exit 1
fi
echo "RBAC guard tests passed (${checks} checks)"
