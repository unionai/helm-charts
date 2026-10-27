#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CHART="${SCRIPT_DIR}/../charts/dataplane"

RELEASE="release-name"
NAMESPACE="union"

echo "Vendoring subchart dependencies..."
helm dependency build "${CHART}"
echo

failures=0
checks=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/helm-charts-rbac-guards.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

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

function expect-provisioner-matches-chart {
  local desc=$1; shift
  local ns=$1; shift
  local out chart provisioned
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${out}" | head -c 300)"
    failures=$((failures + 1))
    return
  fi
  local parse='
    function emit(   i, l, sec, mdname, mdns, rgroup, rkind, rname, subs, s) {
      for (i = 1; i <= n; i++) {
        l = buf[i]
        if (l ~ /^[a-zA-Z]/) sec = l
        if (l == "kind: RoleBinding") isrb = 1
        else if (sec == "metadata:") {
          if (l ~ /^  name: /)      mdname = substr(l, 9)
          if (l ~ /^  namespace: /) mdns   = substr(l, 14)
        }
        else if (sec == "roleRef:") {
          if (l ~ /^  apiGroup: /) rgroup = substr(l, 13)
          if (l ~ /^  kind: /)     rkind  = substr(l, 9)
          if (l ~ /^  name: /)     rname  = substr(l, 9)
        }
        else if (sec == "subjects:") {
          if (l ~ /^  - kind: /)      s = substr(l, 11)
          if (l ~ /^    name: /)      s = s "/" substr(l, 11)
          if (l ~ /^    namespace: /) {
            s = s "/" substr(l, 16)
            subs = subs == "" ? s : subs "," s
          }
        }
      }
      if (isrb && mdname == "union-work-ns" && mdns == NS)
        print "roleRef=" rgroup "/" rkind "/" rname " subjects=" subs
      n = 0; isrb = 0
    }
    $0 == "---" { emit(); next }
    { buf[++n] = $0 }
    END { emit() }
  '
  chart=$(awk -v NS="${ns}" "${parse}" <<<"${out}")
  provisioned=$(awk '
    /^  ab_work_ns_binding\.yaml: \|/ { grab = 1; next }
    grab && /^  [a-z_0-9]+\.yaml: \|/ { grab = 0 }
    grab && /^---$/ { grab = 0 }
    grab { sub(/^    /, ""); print }
  ' <<<"${out}" | sed "s/{{ namespace }}/${ns}/" | awk -v NS="${ns}" "${parse}")
  if [[ -z "${chart}" || "${chart}" != *"subjects="?* ]]; then
    echo "  FAILED   ${desc}"
    echo "           no chart-emitted union-work-ns RoleBinding found in ${ns}"
    failures=$((failures + 1))
  elif [[ "${chart}" != "${provisioned}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           the chart and the provisioner would write different objects into ${ns}"
    echo "           chart:       ${chart}"
    echo "           provisioner: ${provisioned}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

echo "Running RBAC guard tests..."

echo "- supported configurations still render"
expect-render "chart defaults"
expect-render "full-privilege overlay" \
  --set singleNamespace=false \
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
expect-refusal "a cluster-scoped collector under singleNamespace" \
  "cluster-scoped and cannot be granted" \
  --set 'prometheus.kube-state-metrics.collectors={pods,nodes}'
expect-refusal "an empty collector list, which the subchart reads as all 28" \
  "must name at least one collector" \
  --set prometheus.kube-state-metrics.collectors=null

echo "- subchart-native RBAC stays off, so singleNamespace keeps governing it"
expect-refusal "prometheus.rbac.create" \
  "prometheus.rbac.create must stay false" \
  --set prometheus.rbac.create=true
expect-refusal "prometheus.kube-state-metrics.rbac.create" \
  "kube-state-metrics.rbac.create must stay false" \
  --set prometheus.kube-state-metrics.rbac.create=true

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

expect-render "prometheus.forceNamespace naming the release namespace" \
  --set "prometheus.forceNamespace=${NAMESPACE}"
expect-render "kube-state-metrics.namespaceOverride naming the release namespace" \
  --set "prometheus.kube-state-metrics.namespaceOverride=${NAMESPACE}"

echo "- singleNamespace does not reach the kube-prometheus-stack subchart's RBAC"
expect-manifest "the subchart's prometheus ClusterRole is there under singleNamespace" \
  present "name: monitoring-prometheus" \
  --set monitoring.enabled=true --set clusterresourcesync.enabled=true
expect-manifest "and is unchanged outside singleNamespace" \
  present "name: monitoring-prometheus" \
  --set monitoring.enabled=true --set clusterresourcesync.enabled=true \
  --set singleNamespace=false

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

echo "- app serving under singleNamespace renders only when asked for"
zt=(--set zero_trust.enabled=true --set knative-operator.enabled=false --set orgName=test-org)
expect-manifest "the stack renders with apps on and singleNamespace off" present "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set apps.enabled=true --set singleNamespace=false
expect-manifest "and its Kourier half with it" present "name: union-knative-kourier-cluster-read" \
  "${zt[@]}" --set apps.enabled=true --set singleNamespace=false
expect-manifest "apps on at the singleNamespace default renders the stack" present "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set apps.enabled=true

expect-manifest "the default zero-trust install renders, with no Knative stack" \
  absent "name: union-knative-controller-cluster-read" "${zt[@]}"

expect-manifest "and keeps the Envoy gateway" \
  present "union-operator-gateway-envoy-bootstrap" "${zt[@]}"

expect-manifest "the deprecated serving.enabled still turns app serving on" \
  present "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set serving.enabled=true --set singleNamespace=false
expect-manifest "and an explicit apps.enabled still overrides it" absent "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set serving.enabled=true --set apps.enabled=false --set singleNamespace=false

expect-manifest "a stock install renders no Knative stack" \
  absent "name: union-knative-controller-cluster-read"
expect-manifest "with both keys unset, app serving is on outside singleNamespace" \
  present "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set singleNamespace=false
expect-manifest "unless serving.enabled turns it off" \
  absent "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set serving.enabled=false --set singleNamespace=false
expect-manifest "or apps.enabled does" \
  absent "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set apps.enabled=false --set singleNamespace=false
expect-manifest "the deprecated serving.enabled on at the singleNamespace default renders it too" \
  present "name: union-knative-controller-cluster-read" \
  "${zt[@]}" --set serving.enabled=true

echo "- the uvol broker's block-mode default follows singleNamespace"
expect-manifest "a default install renders no block-mode allow list" \
  absent "blockAllow:"
expect-manifest "nor does low_privilege: true, the alias" \
  absent "blockAllow:" --set low_privilege=true
expect-manifest "singleNamespace: false allows block mode for every pod" \
  present "- namespace: '\*'" --set singleNamespace=false
expect-manifest "and so does low_privilege: false" \
  present "- namespace: '\*'" --set low_privilege=false
expect-manifest "an explicit list is used as given under singleNamespace" \
  present "- namespace: builders" --set 'uvolMountBroker.block.allow[0].namespace=builders'
expect-manifest "and an empty list disables block mode outside it" \
  absent "blockAllow:" --set singleNamespace=false --set-json 'uvolMountBroker.block.allow=[]'

echo "- the scope, namespace and identity axes are independent"
expect-manifest "namespaces.enabled pre-seeds outside singleNamespace" \
  present "kind: Namespace" \
  --set singleNamespace=false --set namespaces.enabled=true
expect-manifest "and namespaces.enabled: false leaves the Namespace objects to someone else" \
  absent "kind: Namespace" \
  --set singleNamespace=false --set namespaces.enabled=false
expect-manifest "singleNamespace still suppresses pre-seeding, whatever namespaces.enabled says" \
  absent "kind: Namespace" \
  --set namespaces.enabled=true

expect-manifest "pre-seeded namespaces carry the default Helm retention policy" \
  present "helm.sh/resource-policy: keep" \
  --set singleNamespace=false --set namespaces.enabled=true
expect-manifest "operator annotations merge with it rather than replacing it" \
  present "argocd.argoproj.io/sync-options: Prune=false" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.argocd\.argoproj\.io/sync-options=Prune=false'
expect-manifest "and the Helm default survives that merge" \
  present "helm.sh/resource-policy: keep" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.argocd\.argoproj\.io/sync-options=Prune=false'
expect-manifest "nulling the default drops it, for tooling that owns the lifecycle" \
  absent "helm.sh/resource-policy: keep" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.annotations.helm\.sh/resource-policy=null'
expect-manifest "namespaces.labels lands on the pre-seeded namespaces" \
  present "pod-security.kubernetes.io/enforce: baseline" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.labels.pod-security\.kubernetes\.io/enforce=baseline'
expect-manifest "a custom namespaces.static list replaces the defaults" \
  present "name: my-only-namespace" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.static={my-only-namespace}'
expect-manifest "and the hardcoded six are gone with it" \
  absent "name: flytesnacks-development" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.static={my-only-namespace}'

expect-manifest "clusterresourcesync renders outside singleNamespace with namespaces.enabled unset" \
  present "name: union-syncresources" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "and is still suppressed under singleNamespace, where nothing needs it" \
  absent "name: union-syncresources" \
  --set clusterresourcesync.enabled=true

expect-manifest "commonServiceAccount.enabled: false is honored under singleNamespace" \
  present "serviceAccountName: operator-system" \
  --set commonServiceAccount.enabled=false
expect-manifest "and the shared identity is still the default there" \
  absent "serviceAccountName: operator-system"

expect-binding-subject "the pooled work-ns role binds every declarer under singleNamespace" \
  RoleBinding union-work-ns leaseworker,operator-system,proxy-system,union-webhook-system \
  --set commonServiceAccount.enabled=false
expect-binding-subject "and collapses to one subject when they share an identity" \
  RoleBinding union-work-ns union-system
expect-binding-subject "a per-component cluster role binds the per-component identity" \
  ClusterRoleBinding union-operator-work-ns-cluster-read operator-system \
  --set commonServiceAccount.enabled=false --set singleNamespace=false
expect-binding-subject "and the shared identity reaches it by default" \
  ClusterRoleBinding union-operator-work-ns-cluster-read union-system \
  --set singleNamespace=false

expect-manifest "buildkit moves to its own identity with the rest" \
  present 'serviceAccountName: "union-imagebuilder"' \
  --set commonServiceAccount.enabled=false
expect-manifest "fluentbit stays on the shared name until told otherwise" \
  present "serviceAccountName: union-system" \
  --set commonServiceAccount.enabled=false
expect-manifest "and an explicit name override partitions it" \
  present "serviceAccountName: fluentbit-system" \
  --set commonServiceAccount.enabled=false \
  --set fluentbit.serviceAccount.name=fluentbit-system

echo
echo "- the work-ns role reaches work namespaces and nowhere else"

expect-binding-namespaces "work-ns binds only the listed work namespaces outside singleNamespace" \
  RoleBinding union-work-ns flytesnacks-development,flytesnacks-staging \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.static={flytesnacks-development,flytesnacks-staging}'
expect-binding-namespaces "and binds nowhere when no work namespace is known at render time" \
  RoleBinding union-work-ns "" \
  --set singleNamespace=false
expect-binding-namespaces "under singleNamespace it binds the release namespace, which is the work namespace" \
  RoleBinding union-work-ns union

expect-manifest "work-ns-cluster-read is emitted outside singleNamespace" \
  present "name: union-operator-work-ns-cluster-read" \
  --set singleNamespace=false
expect-manifest "and not at all under singleNamespace" \
  absent "name: union-operator-work-ns-cluster-read"

expect-role-resource "the node informer's grant appears outside singleNamespace with default billing" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false
expect-role-resource "and under Legacy billing with usage collection off" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=Legacy \
  --set config.operator.collectUsages.enabled=false
expect-role-resource "and under billing None while collectUsages is on" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=None
expect-role-resource "and under billing None when only serverless collection is on" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false \
  --set config.configOverrides.operator.serverlessCollectUsages.enabled=true
expect-role-resource "and not with billing None and both usage collectors off" \
  absent union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false
expect-refusal "and a lower-cased model is refused before the gate ever sees it" \
  "config.operator.billing.model must resolve to None, Legacy, Shadow, or ResourceUsage" \
  --set singleNamespace=false --set config.operator.billing.model=legacy
expect-role-resource "and is withheld when cluster permissions are disabled outright" \
  absent union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=Legacy \
  --set config.operator.disableClusterPermissions=true
expect-role-resource "the node informer's grant appears under singleNamespace with default billing" \
  present union-operator-cluster-read nodes
expect-role-resource "and with billing None while collectUsages is on" \
  present union-operator-cluster-read nodes \
  --set config.operator.billing.model=None
expect-manifest "but not with billing None and both usage collectors off" \
  absent "name: union-operator-cluster-read" \
  --set config.operator.billing.model=None --set config.operator.collectUsages.enabled=false
expect-manifest "nor when cluster permissions are disabled outright" \
  absent "name: union-operator-cluster-read" \
  --set config.operator.disableClusterPermissions=true
function expect-collect-usages {
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
  got=$(awk '/^      collectUsages:$/ { n = 1; next } n && /^        enabled:/ { print $2; exit }' <<<"${out}")
  if [[ "${got}" == "${want}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           collectUsages.enabled in the operator config"
    echo "           want: ${want}"
    echo "           got:  ${got:-<not in the render>}"
    failures=$((failures + 1))
  fi
}

expect-collect-usages "singleNamespace leaves collectUsages on" "true"
expect-collect-usages "and low_privilege, its alias, does too" "true" --set low_privilege=true
expect-manifest "and writes no disableClusterPermissions of its own" \
  absent "disableClusterPermissions:"

expect-role-resource "a string \"True\" turns collectUsages on for the gate, as for the operator" \
  present union-operator-cluster-read nodes \
  --set config.operator.billing.model=None --set-string config.operator.collectUsages.enabled=True
expect-role-resource "and so does a string \"1\"" \
  present union-operator-cluster-read nodes \
  --set config.operator.billing.model=None --set-string config.operator.collectUsages.enabled=1
expect-manifest "a string \"0\" turns it off" \
  absent "name: union-operator-cluster-read" \
  --set config.operator.billing.model=None --set-string config.operator.collectUsages.enabled=0
expect-manifest "a string \"T\" disables cluster permissions" \
  absent "name: union-operator-cluster-read" \
  --set-string config.operator.disableClusterPermissions=T
expect-refusal "a value ParseBool rejects is refused" \
  "which the operator cannot read as a boolean" \
  --set-string config.operator.collectUsages.enabled=yes

DCP_TPL="${WORK_DIR}/dcp-templated.yaml"
cat > "${DCP_TPL}" <<'EOF'
config:
  operator:
    disableClusterPermissions: '{{ "false" }}'
EOF
expect-role-resource "disableClusterPermissions is compared as rendered, not by truthiness" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false --values "${DCP_TPL}"
expect-role-resource "an override disables cluster permissions when the values key is unset" \
  absent union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.configOverrides.operator.disableClusterPermissions=true
expect-role-resource "an override enables collectUsages when the values key is unset" \
  present union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=null \
  --set config.configOverrides.operator.collectUsages.enabled=true
expect-role-resource "but not over a values key config.yaml carries" \
  absent union-operator-cluster-read nodes \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false \
  --set config.configOverrides.operator.collectUsages.enabled=true
expect-role-resource "an override turns on PDB management when the values key is unset" \
  present union-operator-work-ns-cluster-read poddisruptionbudgets \
  --set singleNamespace=false --set apps.enabled=true \
  --set config.configOverrides.operator.apps.controller.podDisruptionBudget.enabled=true

expect-role-resource "the API server /metrics scrape is granted outside singleNamespace" \
  present union-operator-cluster-read /metrics \
  --set singleNamespace=false
expect-role-resource "including with billing and usage collection off" \
  present union-operator-cluster-read /metrics \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false

expect-manifest "comp-ns-write appears at stock values, for the tunnel's proxy restart" \
  present "name: union-operator-comp-ns-write"
expect-role-resource "and grants the restart on deployments" \
  present union-operator-comp-ns-write deployments
expect-role-resource "confined by resourceNames to the proxy Deployment" \
  present union-operator-comp-ns-write union-operator-proxy
expect-manifest "and is absent once the tunnel is off, where nothing declares" \
  absent "name: union-operator-comp-ns-write" \
  --set operator.enableTunnelService=false --set config.operator.apiKey.enabled=false
expect-manifest "no component shares a comp-ns Role with another" \
  absent "name: union-comp-ns-write" \
  --set config.operator.secretsWatcher.enabled=true
expect-manifest "nor a comp-ns-read one" \
  absent "name: union-comp-ns-read"

echo
echo "- the runtime provisioner supplies the work-ns binding the chart cannot"

expect-manifest "the work-ns RoleBinding is handed to the provisioner outside singleNamespace" \
  present "ab_work_ns_binding.yaml" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "and the bind grant that lets it reference the pooled role" \
  present union-clusterresourcesync-cluster-write clusterroles \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "confined by resourceNames to the one chart-authored role" \
  present union-clusterresourcesync-cluster-write union-work-ns \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "and ordinary rolebindings authority survives an emptied override" \
  present union-clusterresourcesync-cluster-write rolebindings \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules=null'

expect-manifest "and both are still handed over when the chart also pre-seeds namespaces" \
  present "ab_work_ns_binding.yaml" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-role-resource "with the bind grant kept in the same posture" \
  present union-clusterresourcesync-cluster-write clusterroles \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

expect-provisioner-matches-chart "and the two writers agree on the object, shared identity" \
  flytesnacks-development \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-provisioner-matches-chart "and with per-component identities and propeller on" \
  flytesnacks-development \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}' \
  --set commonServiceAccount.enabled=false --set flytepropeller.enabled=true

echo
echo "- leaseworker and flytepropeller declare into slots instead of owning roles"

expect-binding-subject "the cluster-wide union-leaseworker ClusterRoleBinding is gone" \
  ClusterRoleBinding union-leaseworker "" \
  --set singleNamespace=false
expect-manifest "and flytepropeller-role with it" \
  absent "name: flytepropeller-role" \
  --set singleNamespace=false --set flytepropeller.enabled=true

expect-binding-subject "both join the pooled work-ns role, in registry order" \
  RoleBinding union-work-ns leaseworker,operator-system,proxy-system,union-webhook-system,flytepropeller-system \
  --set commonServiceAccount.enabled=false --set flytepropeller.enabled=true
expect-binding-subject "and drop out of it when disabled" \
  RoleBinding union-work-ns operator-system,proxy-system,union-webhook-system \
  --set commonServiceAccount.enabled=false \
  --set leaseworker.enabled=false --set flytepropeller.enabled=false

echo
echo "- the secrets watcher stays inside the namespaces it is granted"

expect-manifest "the watch list is the release namespace alone by default" \
  present "          - union\$" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false
expect-manifest "and picks up the control plane namespace when one is set" \
  present "          - union-cp\$" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set controlplaneNamespace=union-cp
expect-manifest "an explicit namespaces list wins over the default" \
  absent "          - union-cp\$" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set controlplaneNamespace=union-cp \
  --set 'config.operator.secretsWatcher.namespaces={somewhere-else}'
expect-binding-namespaces "and the grants follow the explicit list rather than controlplaneNamespace" \
  RoleBinding operator-system-secrets-watcher somewhere-else \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set controlplaneNamespace=union-cp \
  --set 'config.operator.secretsWatcher.namespaces={somewhere-else}'
expect-manifest "an explicitly empty list stays empty outside singleNamespace" \
  present "        namespaces: \[\]" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set 'config.operator.secretsWatcher.namespaces=null'
expect-manifest "and is not emitted twice" \
  absent "          - union\$" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set 'config.operator.secretsWatcher.namespaces=null'
expect-role-resource "and the cluster-wide pod list it makes is granted" \
  present union-operator-work-ns-cluster-read pods \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set 'config.operator.secretsWatcher.namespaces=null'
expect-refusal "under singleNamespace an explicitly empty list is refused" \
  "config.operator.secretsWatcher.namespaces is set to an empty list under singleNamespace" \
  --set config.operator.secretsWatcher.enabled=true \
  --set 'config.operator.secretsWatcher.namespaces=null'
expect-render "but not while the watcher is off" \
  --set 'config.operator.secretsWatcher.namespaces=null'

expect-binding-namespaces "the control plane Role is bound in the control plane namespace outside singleNamespace" \
  RoleBinding operator-system-secrets-watcher union-cp \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false \
  --set controlplaneNamespace=union-cp
expect-binding-namespaces "and still under singleNamespace" \
  RoleBinding operator-system-secrets-watcher union-cp \
  --set config.operator.secretsWatcher.enabled=true \
  --set controlplaneNamespace=union-cp
expect-manifest "and nothing is emitted when the control plane is elsewhere" \
  absent "name: operator-system-secrets-watcher" \
  --set config.operator.secretsWatcher.enabled=true --set singleNamespace=false

echo
echo "- namespaces.static and the release namespace"

expect-refusal "listing the release namespace in namespaces.static is refused" \
  "must not contain the release namespace" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.static={union,flytesnacks-development}'
expect-refusal "an empty namespaces.static with namespaces.enabled is refused" \
  "requires a non-empty namespaces.static" \
  --set singleNamespace=false --set namespaces.enabled=true \
  --set 'namespaces.static=null'

expect-render "neither guard fires under singleNamespace, where namespaces.static is ignored" \
  --set namespaces.enabled=true \
  --set 'namespaces.static={union}'
expect-render "including with an empty list" \
  --set namespaces.enabled=true \
  --set 'namespaces.static=null'

echo
echo "- the webhook reaches work namespaces instead of the whole cluster"

expect-manifest "the cluster-wide union-webhook-role is gone outside singleNamespace" \
  absent "name: union-webhook-role" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "and under singleNamespace, where it was a Role" \
  absent "name: union-webhook-role"
expect-role-resource "its resources are in the pooled work-ns role instead" \
  present union-work-ns replicasets/finalizers \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-binding-namespaces "and bound only in the work namespaces the chart knows" \
  RoleBinding union-work-ns flytesnacks-development \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

expect-role-resource "the webhook's cluster-wide Secret read appears outside singleNamespace" \
  present union-webhook-work-ns-cluster-read secrets \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "and not at all under singleNamespace" \
  absent "name: union-webhook-work-ns-cluster-read"
expect-manifest "nor when image-pull-secret injection is disabled" \
  absent "name: union-webhook-work-ns-cluster-read" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled=false

expect-manifest "the self-registration grant appears when the webhook registers itself" \
  present "name: union-webhook-cluster-write" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false
expect-manifest "and not when Helm manages the configuration" \
  absent "name: union-webhook-cluster-write" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "nor under singleNamespace, which disables self-registration on its own" \
  absent "name: union-webhook-cluster-write" \
  --set flytepropellerwebhook.managedConfig=false

function expect-webhook-registration-grant {
  local desc=$1; shift
  local name=$1; shift
  local out got want
  want="kind: ClusterRole
metadata:
  name: union-webhook-cluster-write
rules:
  - apiGroups:
    - admissionregistration.k8s.io
    resources:
    - mutatingwebhookconfigurations
    verbs:
    - create
  - apiGroups:
    - admissionregistration.k8s.io
    resourceNames:
    - ${name}
    resources:
    - mutatingwebhookconfigurations
    verbs:
    - get
    - update"
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk '
    /^kind: ClusterRole$/ { buf = "kind: ClusterRole\n"; inrole = 1; keep = 0; next }
    inrole && /^---$/ { if (keep) printf "%s", buf; inrole = 0; keep = 0; next }
    inrole {
      buf = buf $0 "\n"
      if ($0 == "  name: union-webhook-cluster-write") keep = 1
    }
    END { if (inrole && keep) printf "%s", buf }
  ' <<<"${out}")
  if [[ "${got}" == "${want}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           union-webhook-cluster-write does not match the expected grant"
    diff <(echo "${want}") <(echo "${got}") | sed 's/^/             /'
    failures=$((failures + 1))
  fi
}

expect-webhook-registration-grant "get and update are pinned to the one configuration it registers" \
  union-pod-webhook \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false
expect-webhook-registration-grant "and an override the minimal config discards does not move the pin" \
  union-pod-webhook \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false \
  --set config.core.webhook.serviceName=elsewhere
expect-webhook-registration-grant "with propeller on, the pin follows config.core.webhook.serviceName" \
  union-pod-webhook \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false --set flytepropeller.enabled=true
expect-webhook-registration-grant "including an override, rendered through tpl as the config is" \
  my-hook-union \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false --set flytepropeller.enabled=true \
  --set 'config.core.webhook.serviceName=my-hook-{{ .Release.Namespace }}'
expect-manifest "and the config it pins to carries that same name" \
  present "serviceName: my-hook-union" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false --set flytepropeller.enabled=true \
  --set 'config.core.webhook.serviceName=my-hook-{{ .Release.Namespace }}'
expect-webhook-registration-grant "and the binary's own default when the key is removed" \
  flyte-pod-webhook \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set flytepropellerwebhook.managedConfig=false --set flytepropeller.enabled=true \
  --set config.core.webhook.serviceName=null

echo
echo "- nodeobserver holds the same grant in both scope modes"

expect-binding-subject "nothing binds the old union-nodeobserver Role any more" \
  RoleBinding union-nodeobserver "" \
  --set nodeobserver.enabled=true
expect-role-resource "nodes read is a ClusterRole under singleNamespace" \
  present union-nodeobserver-cluster-read nodes \
  --set nodeobserver.enabled=true
expect-role-resource "and the pods list with it" \
  present union-nodeobserver-cluster-read pods \
  --set nodeobserver.enabled=true
expect-role-resource "the node write is split into its own cluster role" \
  present union-nodeobserver-cluster-write nodes \
  --set nodeobserver.enabled=true
expect-role-resource "and carries nodes outside singleNamespace too" \
  present union-nodeobserver-cluster-write nodes \
  --set nodeobserver.enabled=true --set singleNamespace=false \
  --set clusterresourcesync.enabled=true
expect-manifest "nothing renders when nodeobserver is off" \
  absent "name: union-nodeobserver-cluster-read"

function expect-no-dangling-subjects {
  local desc=$1; shift
  local out report
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' <<<"${out}" | head -c 300)"
    failures=$((failures + 1))
    return
  fi
  report=$(awk -v rel="${NAMESPACE}" '
    function val(s) {
      sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+$/, "", s)
      gsub(/^["\047]|["\047]$/, "", s)
      return s
    }
    function flush() {
      if (skind == "ServiceAccount") {
        n++; sub_doc[n] = doc; sub_name[n] = sname; sub_ns[n] = sns
      }
      skind = ""; sname = ""; sns = ""
    }
    /^---/ { flush(); doc++; inmeta = 0; insubj = 0; next }
    /^[A-Za-z]/ {
      flush(); inmeta = 0; insubj = 0
      if ($0 ~ /^kind:[ \t]/)   { dkind[doc] = val($0) }
      if ($0 == "metadata:")    { inmeta = 1 }
      if ($0 == "subjects:")    { insubj = 1 }
      next
    }
    inmeta && /^  name:[ \t]/      { if (dname[doc] == "") dname[doc] = val($0); next }
    inmeta && /^  namespace:[ \t]/ { if (dns[doc]  == "") dns[doc]  = val($0); next }
    insubj && /^[ \t]*-[ \t]/ {
      flush()
      line = $0; sub(/^[ \t]*-[ \t]*/, "", line)
      if (line ~ /^kind:[ \t]/)      skind = val(line)
      else if (line ~ /^name:[ \t]/) sname = val(line)
      next
    }
    insubj {
      if ($0 ~ /^[ \t]+kind:[ \t]/)           skind = val($0)
      else if ($0 ~ /^[ \t]+name:[ \t]/)      sname = val($0)
      else if ($0 ~ /^[ \t]+namespace:[ \t]/) sns   = val($0)
      next
    }
    END {
      flush()
      for (d in dkind)
        if (dkind[d] == "ServiceAccount" && dname[d] != "")
          sa[(dns[d] == "" ? rel : dns[d]) "/" dname[d]]++
      for (d in sa) {
        sas++
        if (sa[d] > 1) print "duplicate ServiceAccount object: " d " rendered " sa[d] " times"
      }
      for (i = 1; i <= n; i++) {
        d = sub_doc[i]
        if (dkind[d] != "RoleBinding" && dkind[d] != "ClusterRoleBinding") continue
        subjects++
        if (sub_name[i] == "" || sub_ns[i] == "")
          print "invalid subject: " dkind[d] "/" dname[d] " ServiceAccount subject is missing " \
                (sub_name[i] == "" ? "name" : "namespace")
        else if (!((sub_ns[i] "/" sub_name[i]) in sa))
          print "dangling: " dkind[d] "/" dname[d] " -> " sub_ns[i] "/" sub_name[i]
      }
      if (sas == 0)      print "parsed no ServiceAccount objects at all"
      if (subjects == 0) print "parsed no ServiceAccount binding subjects at all"
    }
  ' <<<"${out}")
  if [[ -n "${report}" ]]; then
    echo "  FAILED   ${desc}"
    while IFS= read -r line; do echo "           ${line}"; done <<<"${report}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

function expect-workload-sa {
  local desc=$1; shift
  local deploy=$1; shift
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
  got=$(awk -v name="  name: ${deploy}" '
    $0 == "---" { if (done) finished = 1; iskind = 0; inmatch = 0 }
    $0 == "kind: Deployment" { iskind = 1 }
    iskind && $0 == name && !finished { inmatch = 1; done = 1 }
    inmatch && /^      serviceAccountName:/ {
      sub(/^ *serviceAccountName: */, ""); gsub(/^["\047]|["\047]$/, "")
      print; exit
    }
  ' <<<"${out}")
  if [[ "${got}" != "${want}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           Deployment/${deploy} runs under the wrong ServiceAccount"
    echo "           want: ${want}"
    echo "           got:  ${got:-<no such Deployment, or it sets no serviceAccountName>}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

function expect-resource-group {
  local desc=$1 role=$2 resource=$3 expected=$4; shift 4
  local out got
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk -v role="${role}" -v want="${resource}" '
    function flush(  i) {
      if (has_res) for (i in grp) print i
      delete grp; has_res=0
    }
    /^# Source: / {flush(); kind=""; inrole=0}
    /^kind: / {kind=$2; next}
    /^  name: / {if ((kind=="Role" || kind=="ClusterRole") && $2==role) {inrole=1; found=1} next}
    inrole && /^  - apiGroups:/ {flush(); key="apiGroups"; next}
    inrole && /^    (resources|verbs):[[:space:]]*$/ {key=$1; sub(/:$/,"",key); next}
    inrole && /^    [a-z]/ {key=""}
    inrole && key=="apiGroups" && /^    - / {v=$0; sub(/^    - /,"",v); gsub(/"/,"",v); if (v=="") v="(core)"; grp[v]=1; next}
    inrole && key=="resources" && /^    - / {v=$0; sub(/^    - /,"",v); gsub(/"/,"",v); if (v==want) has_res=1; next}
    END {flush(); if (!found) print "<NO-SUCH-ROLE>"}
  ' <<<"${out}" | sort -u | paste -sd, -)
  if [[ -z "${got}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           no rule in ${role} carries ${resource}"
    failures=$((failures + 1)); return
  fi
  if [[ "${got}" == "${expected}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           apiGroups of the rule carrying ${resource} on ${role}"
    echo "           expected: ${expected}"
    echo "           observed: ${got}"
    failures=$((failures + 1))
  fi
}

function expect-verb-resources {
  local desc=$1 role=$2 verb=$3 expected=$4; shift 4
  local out got
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk -v role="${role}" -v want="${verb}" '
    function flush(  i) {
      if (has_verb) for (i in res) print i
      delete res; has_verb=0
    }
    /^# Source: / {flush(); kind=""; inrole=0}
    /^kind: / {kind=$2; next}
    /^  name: / {if ((kind=="Role" || kind=="ClusterRole") && $2==role) {inrole=1; found=1} next}
    inrole && /^  - apiGroups:/ {flush(); key=""; next}
    inrole && /^    (resources|verbs):[[:space:]]*$/ {key=$1; sub(/:$/,"",key); next}
    inrole && /^    [a-z]/ {key=""}
    inrole && key=="resources" && /^    - / {v=$0; sub(/^    - /,"",v); gsub(/"/,"",v); res[v]=1; next}
    inrole && key=="verbs" && /^    - / {v=$0; sub(/^    - /,"",v); gsub(/"/,"",v); if (v==want) has_verb=1; next}
    END {flush(); if (!found) print "<NO-SUCH-ROLE>"}
  ' <<<"${out}" | sort -u | paste -sd, -)
  if [[ "${got}" == "${expected}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           resources granted ${verb} on ${role}"
    echo "           expected: ${expected:-<none>}"
    echo "           observed: ${got:-<none>}"
    failures=$((failures + 1))
  fi
}

function expect-cleanup-grant-exact {
  local desc=$1; shift
  local out got job
  local want_job="deployment/flytepropeller-webhook
deployment/union-operator-prometheus
mutatingwebhookconfiguration/flyte-pod-webhook
secret/flyte-pod-webhook"
  read -r -d '' want_rbac <<'EXPECTED' || true
kind: ClusterRole
metadata:
  name: flyte-webhook-cleanup-union
rules:
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["mutatingwebhookconfigurations"]
    resourceNames:
      - flyte-pod-webhook
    verbs: ["get", "delete"]
kind: ClusterRoleBinding
metadata:
  name: flyte-webhook-cleanup-union
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flyte-webhook-cleanup-union
subjects:
  - kind: ServiceAccount
    name: flyte-webhook-cleanup
    namespace: union
kind: Role
metadata:
  name: flyte-webhook-cleanup-union
  namespace: union
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames:
      - flytepropeller-webhook
      - union-operator-prometheus
    verbs: ["get", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames:
      - flyte-pod-webhook
    verbs: ["get", "delete"]
kind: RoleBinding
metadata:
  name: flyte-webhook-cleanup-union
  namespace: union
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: flyte-webhook-cleanup-union
subjects:
  - kind: ServiceAccount
    name: flyte-webhook-cleanup
    namespace: union
EXPECTED
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk '
    /^# Source: / {src=$3; inrbac=0}
    src !~ /pre-upgrade-cleanup\.yaml$/ {next}
    /^kind: (Role|ClusterRole|RoleBinding|ClusterRoleBinding)$/ {inrbac=1}
    !inrbac {next}
    /^(apiVersion:|---)$|^apiVersion:/ {next}
    /^    helm\.sh\/hook/ {next}
    /^  annotations:$/ {next}
    {print}
  ' <<<"${out}")
  job=$(awk '
    /^# Source: / {src=$3}
    src !~ /pre-upgrade-cleanup\.yaml$/ {next}
    /kubectl delete [a-z]+ [a-z0-9.-]+/ {
      for (i=1; i<NF; i++) if ($i == "delete") {print $(i+1) "/" $(i+2); break}
    }
  ' <<<"${out}" | sort -u)
  if [[ "${got}" == "${want_rbac}" && "${job}" == "${want_job}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    if [[ "${got}" != "${want_rbac}" ]]; then
      echo "           rendered RBAC differs from the expected migration contract:"
      diff <(echo "${want_rbac}") <(echo "${got}") | sed 's/^/             /'
    fi
    if [[ "${job}" != "${want_job}" ]]; then
      echo "           Job deletions differ from the four legacy objects:"
      diff <(echo "${want_job}") <(echo "${job}") | sed 's/^/             /'
    fi
    failures=$((failures + 1))
  fi
}

function expect-only-webhook-cluster-write {
  local desc=$1; shift
  local out got
  local want="union-knative-webhook-cluster-write"
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk '
    /^kind: ClusterRole$/ { inrole = 1; next }
    /^kind: / { inrole = 0 }
    inrole && /^  name: union-knative-.*-cluster-write$/ { print substr($0, 9); inrole = 0 }
  ' <<<"${out}" | sort -u | paste -sd, -)
  if [[ "${got}" == "${want}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           app-serving cluster-write roles are not the expected set"
    echo "           want: ${want}"
    echo "           got:  ${got:-<none at all, so even the webhook write role is missing>}"
    failures=$((failures + 1))
  fi
}

function expect-webhook-cluster-write-exact {
  local desc=$1; shift
  local out got
  read -r -d '' want <<'EXPECTED' || true
kind: ClusterRole
metadata:
  name: union-knative-webhook-cluster-write
rules:
  - apiGroups:
    - admissionregistration.k8s.io
    resourceNames:
    - webhook.serving.knative.dev
    resources:
    - mutatingwebhookconfigurations
    verbs:
    - get
    - update
  - apiGroups:
    - admissionregistration.k8s.io
    resourceNames:
    - config.webhook.serving.knative.dev
    - validation.webhook.serving.knative.dev
    resources:
    - validatingwebhookconfigurations
    verbs:
    - get
    - update
  - apiGroups:
    - ""
    resourceNames:
    - union
    resources:
    - namespaces/finalizers
    verbs:
    - update
EXPECTED
  checks=$((checks + 1))
  if ! out=$(render "$@" 2>&1); then
    echo "  FAILED   ${desc}"
    echo "           render failed: $(grep -o 'Error:.*' <<<"${out}" | head -c 200)"
    failures=$((failures + 1)); return
  fi
  got=$(awk '
    /^kind: ClusterRole$/ { buf = "kind: ClusterRole\n"; inrole = 1; keep = 0; next }
    inrole && /^---$/ { if (keep) printf "%s", buf; inrole = 0; keep = 0; next }
    inrole {
      buf = buf $0 "\n"
      if ($0 == "  name: union-knative-webhook-cluster-write") keep = 1
    }
    END { if (inrole && keep) printf "%s", buf }
  ' <<<"${out}")
  if [[ "${got}" == "${want}" ]]; then
    echo "  ok       ${desc}"
  else
    echo "  FAILED   ${desc}"
    echo "           the app-serving cluster-write role is not what it must be:"
    diff <(echo "${want}") <(echo "${got}") | sed 's/^/             /'
    failures=$((failures + 1))
  fi
}

expect-cleanup-grant-exact "its grant is exactly the four objects its Job deletes"
expect-cleanup-grant-exact "and outside singleNamespace too" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "and every cleanup object is hook-scoped" \
  present "helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed"

expect-render "an explicitly null imagePullSecrets block still renders" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set-json 'config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets=null'
expect-render "and an explicitly null embeddedSecretManagerConfig around it" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set-json 'config.core.webhook.embeddedSecretManagerConfig=null'
expect-render "and an explicitly null unionProjectSyncConfig" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set-json 'clusterresourcesync.config.cluster_resources.unionProjectSyncConfig=null'

echo
echo "- clusterresourcesync's grant is derived, not an operator default"

expect-role-resource "cluster-wide secrets are no longer granted" \
  absent union-clusterresourcesync-cluster-write secrets \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "nor roles" \
  absent union-clusterresourcesync-cluster-write roles \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "nor clusterrolebindings" \
  absent union-clusterresourcesync-cluster-write clusterrolebindings \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "the namespaces the default template creates are granted" \
  present union-clusterresourcesync-cluster-write namespaces \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "and the serviceaccounts and resourcequotas that follow them" \
  present union-clusterresourcesync-cluster-write resourcequotas \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-role-resource "and none of it depends on the clusterRoleRules override" \
  present union-clusterresourcesync-cluster-write namespaces \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules=null'

expect-verb-resources "nothing is granted delete by default" \
  union-clusterresourcesync-cluster-write delete "" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-verb-resources "and exactly namespaces once cleanup is asked for" \
  union-clusterresourcesync-cluster-write delete "namespaces" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace=true

expect-verb-resources "nothing is granted update" \
  union-clusterresourcesync-cluster-write update "" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-verb-resources "not even with cleanup on" \
  union-clusterresourcesync-cluster-write update "" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace=true
expect-verb-resources "while patch, the verb it does use, covers every provisioned resource" \
  union-clusterresourcesync-cluster-write patch \
  "namespaces,resourcequotas,rolebindings,serviceaccounts" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true

expect-manifest "no auth-delegator binding for clusterresourcesync" \
  absent "union-clustersync-auth-delegator" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-manifest "nor anything else binding system:auth-delegator" \
  absent "name: system:auth-delegator" \
  --set singleNamespace=false --set clusterresourcesync.enabled=true

expect-role-resource "operator-supplied rules are granted cluster-wide" \
  present union-clusterresourcesync-cluster-write widgets \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={example.com}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={widgets}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={get,list,watch}'
expect-role-resource "including where the chart also pre-seeds namespaces" \
  present union-clusterresourcesync-cluster-write widgets \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}' \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={example.com}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={widgets}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={get,list,watch}'

expect-refusal "a wildcard verb in clusterRoleRules is refused" \
  'names verb "*", which is not allowed here' \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={example.com}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={widgets}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={*}'
expect-refusal "and so is escalate, spelled out" \
  'names verb "escalate", which is not allowed here' \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={rbac.authorization.k8s.io}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={roles}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={escalate}'
expect-refusal "nor bind, which only the emitter may write" \
  'names verb "bind", which is not allowed here' \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={rbac.authorization.k8s.io}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={clusterroles}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={bind}'
expect-refusal "an operator-supplied rule with no verbs key at all is refused" \
  'requires a verbs key on every rule' \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={example.com}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={widgets}'

expect-manifest "no clusterresourcesync RBAC under singleNamespace, even when enabled" \
  absent "name: union-clusterresourcesync-cluster-write" \
  --set clusterresourcesync.enabled=true
expect-binding-subject "and it stays out of the pooled work-ns subject list" \
  RoleBinding union-work-ns union-system \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-binding-subject "with per-component identities too, where it would be visible" \
  RoleBinding union-work-ns leaseworker,operator-system,proxy-system,union-webhook-system \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set commonServiceAccount.enabled=false --set apps.enabled=false \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

echo
echo "- cluster-wide reads follow the code paths that make them"

expect-resource-group "the pod-metrics list appears outside singleNamespace with default billing" \
  union-operator-work-ns-cluster-read pods "(core),metrics.k8s.io" \
  --set singleNamespace=false
expect-resource-group "and under ResourceUsage billing with collectUsages off" \
  union-operator-work-ns-cluster-read pods "(core),metrics.k8s.io" \
  --set singleNamespace=false --set config.operator.collectUsages.enabled=false
expect-resource-group "but not under Legacy billing with collectUsages off, which reads nodes instead" \
  union-operator-work-ns-cluster-read pods "(core)" \
  --set singleNamespace=false --set config.operator.billing.model=Legacy \
  --set config.operator.collectUsages.enabled=false
expect-resource-group "nor with billing None and both usage collectors off" \
  union-operator-work-ns-cluster-read pods "(core)" \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false
expect-resource-group "and back when only serverless collection is on" \
  union-operator-work-ns-cluster-read pods "(core),metrics.k8s.io" \
  --set singleNamespace=false --set config.operator.billing.model=None \
  --set config.operator.collectUsages.enabled=false \
  --set config.configOverrides.operator.serverlessCollectUsages.enabled=true

expect-resource-group "under singleNamespace the pod-metrics list is granted in the release namespace" \
  union-operator-comp-ns-read pods "metrics.k8s.io"
expect-resource-group "and with billing None, while collectUsages is on" \
  union-operator-comp-ns-read pods "metrics.k8s.io" \
  --set config.operator.billing.model=None
expect-verb-resources "and not with billing None and collectUsages off" \
  union-operator-comp-ns-read list "daemonsets,deployments,statefulsets" \
  --set config.operator.billing.model=None --set config.operator.collectUsages.enabled=false \
  --set imageBuilder.enabled=false
expect-verb-resources "and not outside singleNamespace, where the cluster-wide grant covers it" \
  union-operator-comp-ns-read list "daemonsets,deployments,statefulsets" \
  --set singleNamespace=false --set imageBuilder.enabled=false

expect-verb-resources "propeller lists namespaces outside singleNamespace, for the workflow GC" \
  union-flytepropeller-work-ns-cluster-read list "flyteworkflows,namespaces,pods,podtemplates" \
  --set singleNamespace=false --set flytepropeller.enabled=true
expect-verb-resources "and does not watch them" \
  union-flytepropeller-work-ns-cluster-read watch "flyteworkflows,pods,podtemplates" \
  --set singleNamespace=false --set flytepropeller.enabled=true
expect-verb-resources "and not when limit-namespace names one namespace" \
  union-flytepropeller-work-ns-cluster-read list "flyteworkflows,pods,podtemplates" \
  --set singleNamespace=false --set flytepropeller.enabled=true \
  --set config.core.propeller.limit-namespace=flytesnacks-development
expect-manifest "and not under singleNamespace, where limit-namespace is the release namespace" \
  absent "name: union-flytepropeller-work-ns-cluster-read" \
  --set flytepropeller.enabled=true

expect-role-resource "the operator lists configmaps cluster-wide when apps are on" \
  present union-operator-work-ns-cluster-read configmaps \
  --set singleNamespace=false --set apps.enabled=true
expect-role-resource "but not when apps are off" \
  absent union-operator-work-ns-cluster-read configmaps \
  --set singleNamespace=false --set apps.enabled=false
expect-role-resource "PodDisruptionBudgets are not read while PDB management is off" \
  absent union-operator-work-ns-cluster-read poddisruptionbudgets \
  --set singleNamespace=false --set apps.enabled=true
expect-role-resource "and are once it is on" \
  present union-operator-work-ns-cluster-read poddisruptionbudgets \
  --set singleNamespace=false --set apps.enabled=true \
  --set config.operator.apps.controller.podDisruptionBudget.enabled=true
expect-role-resource "but not with apps off, where the controller never starts" \
  absent union-operator-work-ns-cluster-read poddisruptionbudgets \
  --set singleNamespace=false --set apps.enabled=false \
  --set config.operator.apps.controller.podDisruptionBudget.enabled=true
expect-role-resource "under singleNamespace the PDB read and writes are in the release-namespace work-ns Role" \
  present union-work-ns poddisruptionbudgets \
  --set zero_trust.enabled=false --set apps.enabled=true --set gateway.enabled=false \
  --set config.operator.apps.controller.podDisruptionBudget.enabled=true
expect-role-resource "and not while PDB management is off" \
  absent union-work-ns poddisruptionbudgets \
  --set zero_trust.enabled=false --set apps.enabled=true --set gateway.enabled=false
expect-role-resource "outside singleNamespace work-ns carries the PDB writes" \
  present union-work-ns poddisruptionbudgets \
  --set singleNamespace=false --set apps.enabled=true \
  --set config.operator.apps.controller.podDisruptionBudget.enabled=true \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-verb-resources "both are list and watch, the complete watched set with apps and PDBs on" \
  union-operator-work-ns-cluster-read watch \
  "configmaps,configurations,namespaces,poddisruptionbudgets,pods,podtemplates,resourcequotas,revisions,services" \
  --set singleNamespace=false --set apps.enabled=true \
  --set config.operator.apps.controller.podDisruptionBudget.enabled=true

echo
echo "App-serving ServiceAccounts"

APPS=(--set zero_trust.enabled=true --set apps.enabled=true --set singleNamespace=false
      --set global.ORG_NAME=test-org --set clusterresourcesync.enabled=true)

expect-no-dangling-subjects "no binding points at a ServiceAccount that does not exist" \
  "${APPS[@]}"
expect-no-dangling-subjects "and none does with per-component identities either" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-no-dangling-subjects "nor anywhere else in the chart, at either scope" \
  --set commonServiceAccount.enabled=false
expect-no-dangling-subjects "nor outside singleNamespace with per-component identities" \
  --set commonServiceAccount.enabled=false --set singleNamespace=false \
  --set clusterresourcesync.enabled=true

expect-manifest "no per-binary ServiceAccount object exists at the default" \
  absent "name: knative-controller" "${APPS[@]}"

while read -r deploy sa; do
  expect-workload-sa "${deploy} runs as ${sa} when the common account is off" \
    "${deploy}" "${sa}" "${APPS[@]}" --set commonServiceAccount.enabled=false
  expect-workload-sa "and as the common account when it is on: ${deploy}" \
    "${deploy}" union-system "${APPS[@]}"
done <<'WORKLOADS'
controller knative-controller
webhook knative-webhook
autoscaler knative-autoscaler
autoscaler-hpa knative-autoscaler
activator knative-activator
net-kourier-controller net-kourier
WORKLOADS

echo
echo "App-serving RBAC"

while read -r component sa; do
  expect-binding-subject "${component}'s cluster-read role binds ${sa}" \
    ClusterRoleBinding "union-knative-${component}-cluster-read" "${sa}" \
    "${APPS[@]}" --set commonServiceAccount.enabled=false
  expect-binding-subject "and the common account when identities are shared: ${component}" \
    ClusterRoleBinding "union-knative-${component}-cluster-read" union-system "${APPS[@]}"
done <<'COMPONENTS'
controller knative-controller
webhook knative-webhook
autoscaler knative-autoscaler
activator knative-activator
kourier net-kourier
COMPONENTS

for c in controller webhook autoscaler activator kourier; do
  for v in create update patch delete deletecollection; do
    expect-verb-resources "knative-${c}'s cluster-read role grants no ${v}" \
      "union-knative-${c}-cluster-read" "${v}" "" "${APPS[@]}" --set commonServiceAccount.enabled=false
  done
done

expect-verb-resources "the webhook's cluster-write grants update on exactly its three targets" \
  union-knative-webhook-cluster-write update \
  "mutatingwebhookconfigurations,namespaces/finalizers,validatingwebhookconfigurations" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and no cluster-scoped create anywhere in the app-serving set" \
  union-knative-webhook-cluster-write create "" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-webhook-cluster-write-exact "and every rule of it stays pinned to named objects" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-only-webhook-cluster-write "and it is the only app-serving cluster-write role there is" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false

expect-verb-resources "the autoscaler's release-namespace write role carries endpointslices/restricted" \
  union-knative-autoscaler-comp-ns-write create "endpointslices,endpointslices/restricted,leases,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "and the work-ns role carries it without the wildcard contributors" \
  present union-work-ns "endpoints/restricted" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false \
  --set leaseworker.enabled=false --set flytepropeller.enabled=false \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

expect-verb-resources "net-kourier's cluster read is exactly its four informers" \
  union-knative-kourier-cluster-read list "endpoints,ingresses,pods,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "and names no literal Secret resource" \
  absent union-knative-kourier-cluster-read secrets \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "nor any Secret through a resource wildcard: it watches only those four" \
  union-knative-kourier-cluster-read watch "endpoints,ingresses,pods,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and gets nothing cluster-wide" \
  union-knative-kourier-cluster-read get "" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "the controller gets nothing cluster-wide" \
  union-knative-controller-cluster-read get "" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "and reaches no Secret through this role at all" \
  absent union-knative-controller-cluster-read secrets \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "nor any ServiceAccount" \
  absent union-knative-controller-cluster-read serviceaccounts \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and its list set is unchanged by that move" \
  union-knative-controller-cluster-read list \
  "'*',deployments,endpoints,namespaces,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "the autoscaler's cluster read is exactly its informers" \
  union-knative-autoscaler-cluster-read list "'*',deployments,endpointslices,horizontalpodautoscalers,leases,pods,revisions,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and the same set under watch" \
  union-knative-autoscaler-cluster-read watch "'*',deployments,endpointslices,horizontalpodautoscalers,leases,pods,revisions,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and it gets nothing cluster-wide" \
  union-knative-autoscaler-cluster-read get "" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "and no core endpoints rule returns to it" \
  absent union-knative-autoscaler-cluster-read "endpoints" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-resource-group "and the informer it reads through is the discovery.k8s.io one" \
  union-knative-autoscaler-cluster-read endpointslices "discovery.k8s.io" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-resource-group "while the controller's restricted subresource stays in core" \
  union-work-ns "endpoints/restricted" "(core)" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
for r in secrets serviceaccounts; do
  expect-role-resource "digest resolution reaches ${r} through the work-ns role" \
    present union-work-ns "${r}" \
    "${APPS[@]}" --set commonServiceAccount.enabled=false \
    --set leaseworker.enabled=false --set flytepropeller.enabled=false \
    --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
done

for c in controller webhook autoscaler activator kourier; do
  expect-verb-resources "knative-${c} cannot create pods cluster-wide" \
    "union-knative-${c}-cluster-read" create "" \
    "${APPS[@]}" --set commonServiceAccount.enabled=false
done

expect-binding-subject "the work-ns pool gains exactly the three app-serving writers" \
  RoleBinding union-work-ns \
  leaseworker,operator-system,proxy-system,union-webhook-system,knative-controller,knative-autoscaler,net-kourier \
  "${APPS[@]}" --set commonServiceAccount.enabled=false \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'
expect-provisioner-matches-chart "the provisioner's binding still matches the chart's, with app serving on" \
  flytesnacks-development \
  "${APPS[@]}" --set commonServiceAccount.enabled=false \
  --set namespaces.enabled=true --set 'namespaces.static={flytesnacks-development}'

expect-verb-resources "leaseworker's comp-ns-read is its Endpoints watch and nothing else" \
  union-leaseworker-comp-ns-read get "endpoints"
expect-verb-resources "and the operator's is its pod-metrics list, the image builder's informers and the snapshot's workload reads" \
  union-operator-comp-ns-read list "configmaps,daemonsets,deployments,pods,secrets,statefulsets"
expect-verb-resources "with get on the snapshot's workloads, component ConfigMaps and shard PodTemplate" \
  union-operator-comp-ns-read get "configmaps,daemonsets,deployments,podtemplates,statefulsets"
expect-verb-resources "and the same get with the image builder off" \
  union-operator-comp-ns-read get "configmaps,daemonsets,deployments,podtemplates,statefulsets" --set imageBuilder.enabled=false
expect-verb-resources "the proxy's comp-ns-read is its ClusterConfig service's ConfigMap get" \
  union-proxy-comp-ns-read get "configmaps"
expect-verb-resources "and grants no list, so the proxy caches no release-namespace ConfigMaps" \
  union-proxy-comp-ns-read list ""
for v in create update patch delete deletecollection; do
  expect-verb-resources "leaseworker's comp-ns-read grants no ${v}" \
    union-leaseworker-comp-ns-read "${v}" ""
  expect-verb-resources "the operator's comp-ns-read grants no ${v}" \
    union-operator-comp-ns-read "${v}" ""
done

READ_SET="'*',configmaps,deployments,events,flyteworkflows,pods,pods/log,podtemplates,rayjobs,replicasets/finalizers,resourcequotas,secrets"
for v in get list watch; do
  expect-verb-resources "work-ns grants ${v} on its full default resource set" \
    union-work-ns "${v}" "${READ_SET}"
done
expect-verb-resources "work-ns grants create on the writable subset" \
  union-work-ns create \
  "'*',configmaps,deployments,flyteworkflows,pods,podtemplates,replicasets/finalizers,resourcequotas,secrets"
expect-verb-resources "and update on the same subset less flyteworkflows" \
  union-work-ns update \
  "'*',configmaps,deployments,pods,podtemplates,replicasets/finalizers,resourcequotas,secrets"
expect-verb-resources "work-ns grants patch only where something patches" \
  union-work-ns patch \
  "'*',pods,replicasets/finalizers,secrets"
expect-verb-resources "work-ns grants delete on less than it creates" \
  union-work-ns delete \
  "'*',configmaps,deployments,flyteworkflows,pods,podtemplates,resourcequotas,secrets"
expect-verb-resources "and deletecollection on nothing" \
  union-work-ns deletecollection ""
expect-verb-resources "until propeller is on, whose garbage collector is the one caller" \
  union-work-ns deletecollection "flyteworkflows,flyteworkflows/finalizers" \
  --set flytepropeller.enabled=true

expect-verb-resources "work-ns grants get on its full app-serving resource set" \
  union-work-ns get \
  "'*','*/finalizers','*/status',configmaps,configurations,deployments,endpoints,events,flyteworkflows,horizontalpodautoscalers,images,ingresses,metrics,metrics/status,podautoscalers,podautoscalers/status,pods,pods/log,podtemplates,rayjobs,replicasets/finalizers,resourcequotas,revisions,secrets,serverlessservices,serverlessservices/status,serviceaccounts,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and create on the subset that is created" \
  union-work-ns create \
  "'*','*/finalizers','*/status',configmaps,configurations,deployments,endpoints,endpoints/restricted,events,flyteworkflows,horizontalpodautoscalers,images,metrics,metrics/status,podautoscalers,podautoscalers/status,pods,podtemplates,replicasets/finalizers,resourcequotas,revisions,secrets,serverlessservices,serverlessservices/status,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and update on the subset that is updated" \
  union-work-ns update \
  "'*','*/finalizers','*/status',configmaps,configurations,deployments,endpoints,events,horizontalpodautoscalers,images,ingresses/status,metrics,metrics/status,podautoscalers,podautoscalers/status,pods,podtemplates,replicasets/finalizers,resourcequotas,revisions,secrets,serverlessservices,serverlessservices/status,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and patch, which is the only thing conveying deployments/scale" \
  union-work-ns patch \
  "'*','*/finalizers','*/status',deployments,deployments/scale,endpoints,events,horizontalpodautoscalers,images,ingresses,metrics,metrics/status,podautoscalers,podautoscalers/status,pods,replicasets/finalizers,secrets,serverlessservices,serverlessservices/status,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false

expect-verb-resources "the autoscaler's comp-ns-write covers the statforwarder's objects" \
  union-knative-autoscaler-comp-ns-write get "endpointslices,leases,services" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-role-resource "and no core endpoints rule survives the 1.23 bump" \
  absent union-knative-autoscaler-comp-ns-write "endpoints" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-resource-group "and its endpointslices rule is in discovery.k8s.io, not core" \
  union-knative-autoscaler-comp-ns-write endpointslices "discovery.k8s.io" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-resource-group "as is the restricted subresource it pairs with" \
  union-knative-autoscaler-comp-ns-write "endpointslices/restricted" "discovery.k8s.io" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "the knative webhook's is one Secret it creates and renews, and its leader-election lease" \
  union-knative-webhook-comp-ns-write create "leases,secrets" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
for v in patch delete deletecollection; do
  expect-verb-resources "and it grants no ${v} on it" \
    union-knative-webhook-comp-ns-write "${v}" "" \
    "${APPS[@]}" --set commonServiceAccount.enabled=false
done
expect-verb-resources "the controller's is its leader-election lease alone" \
  union-knative-controller-comp-ns-write get "leases" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-verb-resources "and carries no Secret of anyone else's" \
  union-knative-controller-comp-ns-write get "leases" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false --set config.operator.secretsWatcher.enabled=true

SYNCER=(--set config.operator.syncClusterConfig.enabled=true --set config.operator.apiKey.enabled=false
  --set operator.enableTunnelService=false)
expect-verb-resources "the cluster-config syncer gets its targets" \
  union-operator-comp-ns-write get "configmaps,deployments,podtemplates" "${SYNCER[@]}"
for v in create list watch patch delete; do
  expect-verb-resources "and never ${v}s them" \
    union-operator-comp-ns-write "${v}" "" "${SYNCER[@]}"
done
expect-manifest "and is pinned to the propeller ConfigMap by name" \
  present "    - flyte-propeller-config" \
  --set config.operator.syncClusterConfig.enabled=true

for r in union-operator-work-ns-cluster-read union-proxy-work-ns-cluster-read \
         union-operator-comp-ns-read union-proxy-comp-ns-read \
         union-leaseworker-work-ns-cluster-read union-webhook-work-ns-cluster-read \
         union-knative-controller-cluster-read union-knative-webhook-cluster-read \
         union-knative-autoscaler-cluster-read union-knative-activator-cluster-read \
         union-knative-kourier-cluster-read \
         union-leaseworker-comp-ns-read \
         union-knative-controller-comp-ns-read union-knative-webhook-comp-ns-read \
         union-knative-autoscaler-comp-ns-read union-knative-activator-comp-ns-read \
         union-knative-kourier-comp-ns-read; do
  for v in create update patch delete deletecollection; do
    expect-verb-resources "${r} grants no ${v}" \
      "${r}" "${v}" "" \
      "${APPS[@]}" --set commonServiceAccount.enabled=false
  done
done

for v in create update patch delete deletecollection; do
  expect-verb-resources "union-flytepropeller-work-ns-cluster-read grants no ${v}" \
    union-flytepropeller-work-ns-cluster-read "${v}" "" \
    "${APPS[@]}" --set commonServiceAccount.enabled=false \
    --set flytepropeller.enabled=true
done

expect-render "every declared slot key is a known slot" \
  "${APPS[@]}" --set commonServiceAccount.enabled=false
if grep -q "does not exist. Known slots:" "${CHART}/templates/common/rbac.yaml"; then
  echo "  ok       the unknown-slot-key guard is wired in"
  checks=$((checks + 1))
else
  echo "  FAILED   the unknown-slot-key guard is missing from common/rbac.yaml"
  checks=$((checks + 1)); failures=$((failures + 1))
fi

if grep -q 'merge (dict "verbs"' "${CHART}/templates/_rbac.tpl"; then
  echo "  FAILED   emitSlot still stamps verbs onto rules"
  checks=$((checks + 1)); failures=$((failures + 1))
else
  echo "  ok       emitSlot no longer stamps verbs"
  checks=$((checks + 1))
fi
if grep -q 'dataplane.rbac.verbAllowlist' "${CHART}/templates/_rbac.tpl"; then
  echo "  FAILED   verbAllowlist survives; the read/write split should come from the slot name"
  checks=$((checks + 1)); failures=$((failures + 1))
else
  echo "  ok       verbAllowlist is gone"
  checks=$((checks + 1))
fi
if grep -q 'hasSuffix "-read" $.slot' "${CHART}/templates/_rbac.tpl"; then
  echo "  ok       a -read slot's allowlist is still derived from its name"
  checks=$((checks + 1))
else
  echo "  FAILED   the -read suffix derivation is gone; read slots now admit write verbs"
  checks=$((checks + 1)); failures=$((failures + 1))
fi

echo
echo "- work-ns alone holds the all-groups wildcard"

function role-rules {
  local role=$1 file=$2
  (cd "${SCRIPT_DIR}/.." && uv run --quiet python tests/lib/rbac_rules.py rules "${role}" <"${file}")
}

function expect-rule {
  local desc=$1 want=$2 role=$3 line=$4; shift 4
  local out got
  checks=$((checks + 1))
  out="${WORK_DIR}/expect-rule.yaml"
  if ! render "$@" >"${out}" 2>&1; then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' "${out}" | head -c 300)"
    failures=$((failures + 1)); return
  fi
  got=$(role-rules "${role}" "${out}")
  if grep -qxF -- "${line}" <<<"${got}"; then
    if [[ "${want}" == "present" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected ${role} not to carry '${line}', but it does"
      failures=$((failures + 1))
    fi
  else
    if [[ "${want}" == "absent" ]]; then
      echo "  ok       ${desc}"
    else
      echo "  FAILED   ${desc}"
      echo "           expected ${role} to carry '${line}'"
      echo "           it carries: $(paste -sd';' - <<<"${got}")"
      failures=$((failures + 1))
    fi
  fi
}

KNATIVE_READ_WILDCARDS="ClusterRole/union-knative-autoscaler-cluster-read apiGroups=autoscaling.internal.knative.dev,networking.internal.knative.dev resources=* verbs=list,watch
ClusterRole/union-knative-controller-cluster-read apiGroups=serving.knative.dev,autoscaling.internal.knative.dev,networking.internal.knative.dev,caching.internal.knative.dev resources=* verbs=list,watch"
function expect-wildcards-contained {
  local desc=$1; shift
  local out got stray
  checks=$((checks + 1))
  out="${WORK_DIR}/expect-wildcards.yaml"
  if ! render "$@" >"${out}" 2>&1; then
    echo "  FAILED   ${desc}"
    echo "           expected the render to succeed, but it was refused:"
    echo "           $(grep -o 'Error:.*' "${out}" | head -c 300)"
    failures=$((failures + 1)); return
  fi
  got=$(cd "${SCRIPT_DIR}/.." && uv run --quiet python tests/lib/rbac_rules.py wildcards union-work-ns <"${out}")
  stray=$(grep -vxF -f <(printf '%s\n' "${KNATIVE_READ_WILDCARDS}") <<<"${got}" || true)
  if [[ -n "${stray}" ]]; then
    echo "  FAILED   ${desc}"
    echo "           wildcard rules outside union-work-ns:"
    sed 's/^/             /' <<<"${stray}"
    failures=$((failures + 1))
  else
    echo "  ok       ${desc}"
  fi
}

WILD_ALL=(--set nodeobserver.enabled=true --set uvolMountBroker.enabled=true
  --set flytepropeller.enabled=true --set imageBuilder.enabled=true
  --set config.operator.secretsWatcher.enabled=true
  --set config.operator.syncClusterConfig.enabled=true
  --set flytepropellerwebhook.managedConfig=false
  --set flytepropellerwebhook.certificate.provider=legacy
  --set 'taskPluginClusterReadRules[0].apiGroups={ray.io}'
  --set 'taskPluginClusterReadRules[0].resources={rayjobs,rayclusters}')
expect-wildcards-contained "single namespace, every component" "${WILD_ALL[@]}"
expect-wildcards-contained "multi-namespace, every component, shared identity" \
  "${WILD_ALL[@]}" --set singleNamespace=false --set clusterresourcesync.enabled=true
expect-wildcards-contained "multi-namespace, every component, per-component identities" \
  "${WILD_ALL[@]}" --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set commonServiceAccount.enabled=false
expect-wildcards-contained "multi-namespace with zero-trust app serving" \
  "${WILD_ALL[@]}" "${APPS[@]}" --set commonServiceAccount.enabled=false
expect-refusal "the emitter refuses an all-groups rule outside work-ns" \
  'Only the work-ns slot may name every API group' \
  --set singleNamespace=false --set clusterresourcesync.enabled=true \
  --set 'clusterresourcesync.clusterRoleRules[0].apiGroups={*}' \
  --set 'clusterresourcesync.clusterRoleRules[0].resources={pods}' \
  --set 'clusterresourcesync.clusterRoleRules[0].verbs={get}'
expect-rule "and work-ns keeps its wildcard" present union-work-ns \
  "* * create,delete,get,list,patch,update,watch -" --set singleNamespace=false

echo
echo "- taskPluginClusterReadRules grants plugin CRD reads at multi-namespace only"

PLUGIN_RAY=(--set 'taskPluginClusterReadRules[0].apiGroups={ray.io}'
  --set 'taskPluginClusterReadRules[0].resources={rayjobs,rayclusters}')
expect-rule "leaseworker gets the entry, defaulted to list and watch" present \
  union-leaseworker-work-ns-cluster-read "ray.io rayclusters list,watch -" \
  "${PLUGIN_RAY[@]}" --set singleNamespace=false
expect-rule "flytepropeller gets the same entry when it is enabled" present \
  union-flytepropeller-work-ns-cluster-read "ray.io rayclusters list,watch -" \
  "${PLUGIN_RAY[@]}" --set singleNamespace=false --set flytepropeller.enabled=true
expect-rule "an explicit get is admitted" present \
  union-leaseworker-work-ns-cluster-read "ray.io rayjobs get -" \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].verbs={get}' --set singleNamespace=false
expect-manifest "nothing renders under singleNamespace" \
  absent "rayclusters" "${PLUGIN_RAY[@]}"
expect-manifest "and nothing renders when the key is unset" \
  absent "rayclusters" --set singleNamespace=false
expect-refusal "an all-groups wildcard is refused" \
  'taskPluginClusterReadRules[0].apiGroups contains "*"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].apiGroups={*}' --set singleNamespace=false
expect-refusal "a resource wildcard inside a named group is refused" \
  'taskPluginClusterReadRules[0].resources contains "*"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].resources={*}' --set singleNamespace=false
expect-refusal "a wildcard verb is refused" \
  'taskPluginClusterReadRules[0].verbs contains "*"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].verbs={*}' --set singleNamespace=false
expect-refusal "a write verb is refused" \
  'taskPluginClusterReadRules[0].verbs names "create"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].verbs={create}' --set singleNamespace=false
expect-refusal "a write verb is refused under singleNamespace too" \
  'taskPluginClusterReadRules[0].verbs names "create"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].verbs={create}'
expect-refusal "and so is a wildcard" \
  'taskPluginClusterReadRules[0].resources contains "*"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].resources={*}'
expect-refusal "the core group is refused" \
  'taskPluginClusterReadRules[0].apiGroups names "", a built-in Kubernetes group' \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":[""],"resources":["secrets"]}]' \
  --set singleNamespace=false
expect-refusal "under singleNamespace too" \
  'taskPluginClusterReadRules[0].apiGroups names "", a built-in Kubernetes group' \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":[""],"resources":["secrets"]}]'
expect-refusal "a dotless built-in group is refused" \
  'apiGroups names "apps", a built-in Kubernetes group' \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":["apps"],"resources":["deployments"]}]' \
  --set singleNamespace=false
expect-refusal "rbac.authorization.k8s.io is refused" \
  'apiGroups names "rbac.authorization.k8s.io", a built-in Kubernetes group' \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":["rbac.authorization.k8s.io"],"resources":["clusterroles"]}]' \
  --set singleNamespace=false
expect-refusal "certificates.k8s.io is refused" \
  'apiGroups names "certificates.k8s.io", a built-in Kubernetes group' \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":["certificates.k8s.io"],"resources":["certificatesigningrequests"]}]' \
  --set singleNamespace=false
expect-rule "a plugin CRD under k8s.io is admitted" present \
  union-leaseworker-work-ns-cluster-read "sparkoperator.k8s.io sparkapplications list,watch -" \
  --set-json 'taskPluginClusterReadRules=[{"apiGroups":["sparkoperator.k8s.io"],"resources":["sparkapplications"]}]' \
  --set singleNamespace=false
expect-refusal "resourceNames is refused" \
  'has key "resourceNames"' \
  "${PLUGIN_RAY[@]}" --set 'taskPluginClusterReadRules[0].resourceNames={x}' --set singleNamespace=false

echo
echo "- the leaseworker's event watcher is granted at multi-namespace only"

expect-rule "multi-namespace: events.k8s.io events, list and watch" present \
  union-leaseworker-work-ns-cluster-read "events.k8s.io events list,watch -" \
  --set singleNamespace=false --set commonServiceAccount.enabled=false
expect-manifest "singleNamespace: no leaseworker cluster read at all" \
  absent "name: union-leaseworker-work-ns-cluster-read"

echo "- node-capacity reporting reads nodes, and pods with clusterWidePods, in both scope modes"
CAP=(--set config.operator.clusterHealth.nodeCapacity.enabled=true)
PODS=(--set config.operator.clusterHealth.nodeCapacity.clusterWidePods=true)
NO_INFORMER=(--set config.operator.billing.model=None --set config.operator.collectUsages.enabled=false
  --set config.operator.disableClusterPermissions=true)
for scope in "singleNamespace=true" "singleNamespace=false"; do
  expect-rule "${scope}: the informer's nodes rule carries no get without capacity reporting" present \
    union-operator-cluster-read "core nodes list,watch -" --set "${scope}"
  expect-rule "${scope}: capacity reporting adds get to the nodes rule" present \
    union-operator-cluster-read "core nodes get,list,watch -" --set "${scope}" "${CAP[@]}"
  expect-rule "${scope}: and grants it with the informer's gate off" present \
    union-operator-cluster-read "core nodes get,list,watch -" \
    --set "${scope}" "${CAP[@]}" "${NO_INFORMER[@]}"
  expect-rule "${scope}: and reads no pods without clusterWidePods" absent \
    union-operator-cluster-read "core pods get,list,watch -" --set "${scope}" "${CAP[@]}"
  expect-rule "${scope}: clusterWidePods adds a cluster-wide pod read" present \
    union-operator-cluster-read "core pods get,list,watch -" --set "${scope}" "${CAP[@]}" "${PODS[@]}"
  expect-rule "${scope}: also with the informer's gate off" present \
    union-operator-cluster-read "core pods get,list,watch -" \
    --set "${scope}" "${CAP[@]}" "${PODS[@]}" "${NO_INFORMER[@]}"
  expect-verb-resources "${scope}: and nothing else, with the informer's gate off" \
    union-operator-cluster-read list "nodes,pods" \
    --set "${scope}" "${CAP[@]}" "${PODS[@]}" "${NO_INFORMER[@]}"
  expect-rule "${scope}: clusterWidePods alone grants no pod read" absent \
    union-operator-cluster-read "core pods get,list,watch -" --set "${scope}" "${PODS[@]}"
  expect-manifest "${scope}: and no standalone node-capacity ClusterRole renders" \
    absent "name: union-operator-system-node-capacity" --set "${scope}" "${CAP[@]}" "${PODS[@]}"
done

echo "- node-bootstrap removes its startup taint through its own cluster slots, in both scope modes"
NB=(--set nodeBootstrap.enabled=true --set nodeBootstrap.cloudProvider=aws)
NB_NO_TAINT=("${NB[@]}" --set nodeBootstrap.startupTaintKey=)
for scope in "singleNamespace=true" "singleNamespace=false"; do
  expect-manifest "${scope}: no node-bootstrap read role without a taint key" \
    absent "name: union-node-bootstrap-cluster-read" --set "${scope}" "${NB_NO_TAINT[@]}"
  expect-manifest "${scope}: nor a write role" \
    absent "name: union-node-bootstrap-cluster-write" --set "${scope}" "${NB_NO_TAINT[@]}"
  expect-manifest "${scope}: and its ServiceAccount mounts no token" \
    present "automountServiceAccountToken: false" --set "${scope}" "${NB_NO_TAINT[@]}" \
    --set uvolMountBroker.enabled=false
  expect-rule "${scope}: with a taint key it reads its node" present \
    union-node-bootstrap-cluster-read "core nodes get -" --set "${scope}" "${NB[@]}"
  expect-rule "${scope}: and updates it, unpinned" present \
    union-node-bootstrap-cluster-write "core nodes update -" --set "${scope}" "${NB[@]}"
  for v in get list watch create update patch delete deletecollection; do
    want_read=""; want_write=""
    [[ ${v} == get ]] && want_read="nodes"
    [[ ${v} == update ]] && want_write="nodes"
    expect-verb-resources "${scope}: the read role grants ${v} on exactly '${want_read}'" \
      union-node-bootstrap-cluster-read "${v}" "${want_read}" --set "${scope}" "${NB[@]}"
    expect-verb-resources "${scope}: the write role grants ${v} on exactly '${want_write}'" \
      union-node-bootstrap-cluster-write "${v}" "${want_write}" --set "${scope}" "${NB[@]}"
  done
  expect-binding-subject "${scope}: the write role binds union-node-bootstrap alone" \
    ClusterRoleBinding union-node-bootstrap-cluster-write union-node-bootstrap \
    --set "${scope}" "${NB[@]}"
  expect-manifest "${scope}: and no standalone ${RELEASE}-node-bootstrap ClusterRole renders" \
    absent "name: ${RELEASE}-node-bootstrap$" --set "${scope}" "${NB[@]}"
done
expect-manifest "nothing renders with node-bootstrap off" \
  absent "name: union-node-bootstrap-cluster-write"

echo
echo "- release-namespace calls are granted to the component that makes them"

MULTI=(--set singleNamespace=false)
expect-rule "operator, imageBuilder on, apps off: the reference ConfigMap, pinned" present \
  union-operator-comp-ns-read "core configmaps get,list,watch union-operator" "${MULTI[@]}"
expect-rule "and the mirror-secrets deleter's Secret informer" present \
  union-operator-comp-ns-read "core secrets list,watch -" "${MULTI[@]}"
expect-rule "neither with imageBuilder off" absent \
  union-operator-comp-ns-read "core configmaps get,list,watch union-operator" \
  "${MULTI[@]}" --set imageBuilder.enabled=false
expect-rule "the Secret informer neither" absent \
  union-operator-comp-ns-read "core secrets list,watch -" \
  "${MULTI[@]}" --set imageBuilder.enabled=false
expect-rule "the reference ConfigMap grant is there under singleNamespace too" present \
  union-operator-comp-ns-read "core configmaps get,list,watch union-operator"
for r in deployments daemonsets statefulsets; do
  expect-rule "operator: the cluster snapshot reads ${r} in the release namespace" present \
    union-operator-comp-ns-read "apps ${r} get,list,watch -" "${MULTI[@]}"
  expect-rule "and under singleNamespace, without leaning on work-ns" present \
    union-operator-comp-ns-read "apps ${r} get,list,watch -"
done

expect-rule "operator, tunnel: the token Secret, pinned to operator.secretName" present \
  union-operator-comp-ns-write "core secrets get,update union-secret-auth" "${MULTI[@]}"
expect-rule "and it follows operator.secretName" present \
  union-operator-comp-ns-write "core secrets get,update custom-auth" \
  "${MULTI[@]}" --set operator.secretName=custom-auth
expect-rule "not with the tunnel off" absent \
  union-operator-comp-ns-write "core secrets get,update union-secret-auth" \
  "${MULTI[@]}" --set operator.enableTunnelService=false

expect-rule "operator, Eager API key: create, unpinned" present \
  union-operator-comp-ns-write "core secrets create -" "${MULTI[@]}"
expect-rule "and get/update pinned to the state Secret" present \
  union-operator-comp-ns-write "core secrets get,update union-operator-apikey-state" "${MULTI[@]}"
expect-rule "the pin follows apiKey.stateSecretName" present \
  union-operator-comp-ns-write "core secrets get,update custom-state" \
  "${MULTI[@]}" --set config.operator.apiKey.stateSecretName=custom-state
expect-rule "no create with the API key off" absent \
  union-operator-comp-ns-write "core secrets create -" \
  "${MULTI[@]}" --set config.operator.apiKey.enabled=false

expect-rule "operator, apps: connector-config update, pinned" present \
  union-operator-comp-ns-write "core configmaps update connector-config" "${APPS[@]}"
expect-rule "not with apps off" absent \
  union-operator-comp-ns-write "core configmaps update connector-config" \
  "${MULTI[@]}" --set apps.enabled=false

UNMANAGED=(--set flytepropellerwebhook.managedConfig=false)
expect-rule "webhook, self-registering: its own pod, for the ownerReferences" present \
  union-webhook-comp-ns-read "core pods get -" "${MULTI[@]}" "${UNMANAGED[@]}"
expect-rule "and the ReplicaSet finalizers OwnerReferencesPermissionEnforcement checks" present \
  union-webhook-comp-ns-write "apps replicasets/finalizers update -" "${MULTI[@]}" "${UNMANAGED[@]}"
for v in create update patch delete deletecollection list watch; do
  expect-verb-resources "and its comp-ns-read grants no ${v}" \
    union-webhook-comp-ns-read "${v}" "" "${MULTI[@]}" "${UNMANAGED[@]}"
done
expect-rule "neither when Helm manages the configuration" absent \
  union-webhook-comp-ns-read "core pods get -" "${MULTI[@]}"
expect-rule "nor under singleNamespace, where it never registers" absent \
  union-webhook-comp-ns-read "core pods get -" "${UNMANAGED[@]}"

LEGACY=(--set flytepropellerwebhook.certificate.provider=legacy)
expect-rule "webhook, legacy certs: create, unpinned" present \
  union-webhook-comp-ns-write "core secrets create -" "${MULTI[@]}" "${LEGACY[@]}"
expect-rule "and get/update on the Secret init-certs writes" present \
  union-webhook-comp-ns-write "core secrets get,update union-pod-webhook" "${MULTI[@]}" "${LEGACY[@]}"
expect-rule "which is the binary's default when the webhook mounts propeller's config" present \
  union-webhook-comp-ns-write "core secrets get,update flyte-pod-webhook" \
  "${MULTI[@]}" "${LEGACY[@]}" --set flytepropeller.enabled=true
expect-rule "nothing with another provider" absent \
  union-webhook-comp-ns-write "core secrets create -" "${MULTI[@]}"

expect-rule "the secrets-namespace read: get only" present \
  union-secret-read "core secrets get -" "${MULTI[@]}"
expect-binding-subject "bound to the shared identity by default" \
  RoleBinding union-secret-read union-system "${MULTI[@]}"
expect-binding-subject "and to the webhook and leaseworker identities when split" \
  RoleBinding union-secret-read union-webhook-system,leaseworker \
  "${MULTI[@]}" --set commonServiceAccount.enabled=false
expect-binding-namespaces "in proxy.secretsNamespace" \
  RoleBinding union-secret-read other-secrets \
  "${MULTI[@]}" --set proxy.secretManager.namespace=other-secrets
expect-binding-namespaces "not under singleNamespace with the secrets in the release namespace" \
  RoleBinding union-secret-read ""
expect-binding-namespaces "but under singleNamespace with them elsewhere" \
  RoleBinding union-secret-read other-secrets --set proxy.secretManager.namespace=other-secrets
expect-binding-namespaces "and not when the secret manager is not K8s" \
  RoleBinding union-secret-read "" "${MULTI[@]}" --set proxy.secretManager.type=AWS

echo
echo "- singleNamespace resolves from either key, and low_privilege is only an alias"

expect-manifest "neither key set means single-namespace" \
  present "limitNamespace: ${NAMESPACE}"
expect-manifest "singleNamespace: true is single-namespace" \
  present "limitNamespace: ${NAMESPACE}" \
  --set singleNamespace=true
expect-manifest "singleNamespace: false is multi-namespace" \
  absent "limitNamespace: ${NAMESPACE}" \
  --set singleNamespace=false
expect-manifest "low_privilege: true alone is single-namespace" \
  present "limitNamespace: ${NAMESPACE}" \
  --set low_privilege=true
expect-manifest "low_privilege: false alone is multi-namespace" \
  absent "limitNamespace: ${NAMESPACE}" \
  --set low_privilege=false
expect-manifest "both set and agreeing is honored" \
  absent "limitNamespace: ${NAMESPACE}" \
  --set singleNamespace=false --set low_privilege=false
expect-refusal "both set and disagreeing is refused" \
  "singleNamespace is false but low_privilege is true" \
  --set singleNamespace=false --set low_privilege=true
expect-refusal "and refused the other way round too" \
  "singleNamespace is true but low_privilege is false" \
  --set singleNamespace=true --set low_privilege=false
expect-refusal "an example layered with a low_privilege: true overlay is refused" \
  "singleNamespace is false but low_privilege is true" \
  --set low_privilege=true --values "${CHART}/examples/values.full-privilege.yaml"
expect-refusal "a string is refused rather than read for truthiness" \
  "singleNamespace must be a YAML boolean" \
  --set-string singleNamespace=false
expect-refusal "for the alias too" \
  "low_privilege must be a YAML boolean" \
  --set-string low_privilege=false

echo
echo "- under singleNamespace, cluster-scoped grants come only from the allowlist"

SCOPE_ALLOWLIST="${WORK_DIR}/scope-allowlist.txt"
cat > "${SCOPE_ALLOWLIST}" <<'EOF'
union-operator-cluster-read read core nodes list,watch
union-operator-cluster-read read core nodes get
union-operator-cluster-read read core pods get,list,watch

union-nodeobserver-cluster-read read core nodes get
union-nodeobserver-cluster-read read core pods list
union-nodeobserver-cluster-write unpinned-write core nodes update

union-node-bootstrap-cluster-read read core nodes get
union-node-bootstrap-cluster-write unpinned-write core nodes update

dataplane-nginx-ingressclass read networking.k8s.io ingressclasses get,list,watch

flyte-webhook-cleanup-union read admissionregistration.k8s.io mutatingwebhookconfigurations get flyte-pod-webhook
flyte-webhook-cleanup-union pinned-write admissionregistration.k8s.io mutatingwebhookconfigurations delete flyte-pod-webhook

# App serving on the vendored gateway, which renders under singleNamespace only when
# apps.enabled (or the deprecated serving.enabled) is set. Knative's informers are not
# namespace-scoped, so these reads are cluster-wide in either mode.
union-knative-controller-cluster-read read core services list,watch
union-knative-controller-cluster-read read core endpoints list,watch
union-knative-controller-cluster-read read core namespaces list,watch
union-knative-controller-cluster-read read serving.knative.dev * list,watch
union-knative-controller-cluster-read read autoscaling.internal.knative.dev * list,watch
union-knative-controller-cluster-read read networking.internal.knative.dev * list,watch
union-knative-controller-cluster-read read caching.internal.knative.dev * list,watch
union-knative-controller-cluster-read read apps deployments list,watch
union-knative-activator-cluster-read read core services list,watch
union-knative-activator-cluster-read read core endpoints list,watch
union-knative-activator-cluster-read read serving.knative.dev revisions list,watch
union-knative-autoscaler-cluster-read read core pods list,watch
union-knative-autoscaler-cluster-read read core services list,watch
union-knative-autoscaler-cluster-read read discovery.k8s.io endpointslices list,watch
union-knative-autoscaler-cluster-read read coordination.k8s.io leases list,watch
union-knative-autoscaler-cluster-read read autoscaling.internal.knative.dev * list,watch
union-knative-autoscaler-cluster-read read networking.internal.knative.dev * list,watch
union-knative-autoscaler-cluster-read read serving.knative.dev revisions list,watch
union-knative-autoscaler-cluster-read read apps deployments list,watch
union-knative-autoscaler-cluster-read read autoscaling horizontalpodautoscalers list,watch
union-knative-kourier-cluster-read read core pods list,watch
union-knative-kourier-cluster-read read core endpoints list,watch
union-knative-kourier-cluster-read read core services list,watch
union-knative-kourier-cluster-read read networking.internal.knative.dev ingresses list,watch
union-knative-webhook-cluster-read read admissionregistration.k8s.io mutatingwebhookconfigurations list,watch
union-knative-webhook-cluster-read read admissionregistration.k8s.io validatingwebhookconfigurations list,watch
union-knative-webhook-cluster-read read core namespaces get union
union-knative-webhook-cluster-write read admissionregistration.k8s.io mutatingwebhookconfigurations get webhook.serving.knative.dev
union-knative-webhook-cluster-write pinned-write admissionregistration.k8s.io mutatingwebhookconfigurations update webhook.serving.knative.dev
union-knative-webhook-cluster-write read admissionregistration.k8s.io validatingwebhookconfigurations get config.webhook.serving.knative.dev,validation.webhook.serving.knative.dev
union-knative-webhook-cluster-write pinned-write admissionregistration.k8s.io validatingwebhookconfigurations update config.webhook.serving.knative.dev,validation.webhook.serving.knative.dev
union-knative-webhook-cluster-write pinned-write core namespaces/finalizers update union

outside-namespace operator-system-secrets-watcher

subchart monitoring
subchart metrics-server
subchart opencost
subchart knative-operator
subchart ingress-nginx
subchart dcgm-exporter
subchart fluentbit
EOF

max_features=(
  --set nodeobserver.enabled=true --set uvolMountBroker.enabled=true
  --set flytepropeller.enabled=true --set imageBuilder.enabled=true
  --set config.operator.secretsWatcher.enabled=true
  --set config.operator.syncClusterConfig.enabled=true
  --set controlplaneNamespace=union-cp
  --set config.operator.billing.model=Shadow
  --set config.configOverrides.operator.serverlessCollectUsages.enabled=true
  --set ingress-nginx.enabled=true --set monitoring.enabled=true
  --set metrics-server.enabled=true --set opencost.enabled=true --set cost.enabled=true
  --set dcgm-exporter.enabled=true --set commonServiceAccount.enabled=false
  --set flytepropellerwebhook.managedConfig=false
  --set flytepropellerwebhook.certificate.provider=legacy
  --set 'taskPluginClusterReadRules[0].apiGroups={ray.io}'
  --set 'taskPluginClusterReadRules[0].resources={rayjobs,rayclusters}'
  --set config.operator.clusterHealth.nodeCapacity.enabled=true
  --set config.operator.clusterHealth.nodeCapacity.clusterWidePods=true
  --set nodeBootstrap.enabled=true --set nodeBootstrap.cloudProvider=aws
  --set nodeBootstrap.startupTaintKey=example.com/node-bootstrap-not-ready
)
MAX_APPS="${WORK_DIR}/max-apps.yaml"
MAX_ZT="${WORK_DIR}/max-zero-trust.yaml"
MAX_ZT_APPS="${WORK_DIR}/max-zero-trust-apps.yaml"
scope_renders=()
if render "${max_features[@]}" --set zero_trust.enabled=false \
    --set apps.enabled=true --set gateway.enabled=false --set knative-operator.enabled=true \
    --set config.operator.apps.controller.podDisruptionBudget.enabled=true >"${MAX_APPS}" 2>&1; then
  scope_renders+=(--render "every component, app serving on the knative-operator path=${MAX_APPS}")
else
  checks=$((checks + 1)); failures=$((failures + 1))
  echo "  FAILED   the max-features render with app serving: $(grep -o 'Error:.*' "${MAX_APPS}" | head -c 300)"
fi
if render "${max_features[@]}" --set zero_trust.enabled=true --set knative-operator.enabled=false \
    --set orgName=test-org >"${MAX_ZT}" 2>&1; then
  scope_renders+=(--render "every component, zero trust=${MAX_ZT}")
else
  checks=$((checks + 1)); failures=$((failures + 1))
  echo "  FAILED   the max-features zero-trust render: $(grep -o 'Error:.*' "${MAX_ZT}" | head -c 300)"
fi
if render "${max_features[@]}" --set zero_trust.enabled=true --set knative-operator.enabled=false \
    --set orgName=test-org --set apps.enabled=true >"${MAX_ZT_APPS}" 2>&1; then
  scope_renders+=(--render "every component, zero trust, app serving on the vendored gateway=${MAX_ZT_APPS}")
else
  checks=$((checks + 1)); failures=$((failures + 1))
  echo "  FAILED   the max-features zero-trust render with app serving: $(grep -o 'Error:.*' "${MAX_ZT_APPS}" | head -c 300)"
fi

audit_status=0
scope_report=$(cd "${SCRIPT_DIR}/.." && uv run --quiet python tests/lib/rbac_scope_audit.py \
  --allowlist "${SCOPE_ALLOWLIST}" --chart "${CHART}" --fixtures "${SCRIPT_DIR}/values" \
  --namespace "${NAMESPACE}" "${scope_renders[@]}" 2>&1) || audit_status=$?
echo "${scope_report}"
checks=$((checks + $(grep -cE '^  (ok|FAILED) ' <<<"${scope_report}" || true)))
failures=$((failures + $(grep -cE '^  FAILED ' <<<"${scope_report}" || true)))
if [[ ${audit_status} -ne 0 ]] && ! grep -qE '^  FAILED ' <<<"${scope_report}"; then
  checks=$((checks + 1)); failures=$((failures + 1))
  echo "  FAILED   the scope audit exited ${audit_status} without reporting a failure"
elif ! grep -qE '^  (ok|FAILED) ' <<<"${scope_report}"; then
  checks=$((checks + 1)); failures=$((failures + 1))
  echo "  FAILED   the scope audit produced no results"
fi

if [[ ${failures} -ne 0 ]]; then
  echo "RBAC guard tests: ${failures} of ${checks} checks failed"
  exit 1
fi
echo "RBAC guard tests passed (${checks} checks)"
