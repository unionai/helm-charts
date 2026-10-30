{{- define "dataplane.rbac.components" -}}
{{- $components := list -}}
{{- if .Values.leaseworker.enabled -}}
{{- $components = append $components (dict "name" "leaseworker" "sa" (include "leaseworker.serviceAccountName" .)) -}}
{{- end -}}
{{- if .Values.operator.serviceAccount.create -}}
{{- $components = append $components (dict "name" "operator" "sa" (include "operator.serviceAccountName" .)) -}}
{{- end -}}
{{- if .Values.proxy.serviceAccount.create -}}
{{- $components = append $components (dict "name" "proxy" "sa" (include "proxy.serviceAccountName" .)) -}}
{{- end -}}
{{- if .Values.flytepropellerwebhook.enabled -}}
{{- $components = append $components (dict "name" "webhook" "sa" (include "webhook.serviceAccountName" .)) -}}
{{- end -}}
{{- if .Values.flytepropeller.enabled -}}
{{- $components = append $components (dict "name" "flytepropeller" "sa" "flytepropeller-system") -}}
{{- end -}}
{{- if .Values.nodeobserver.enabled -}}
{{- $components = append $components (dict "name" "nodeobserver" "sa" (include "nodeobserver.serviceAccountName" .)) -}}
{{- end -}}
{{- if .Values.nodeBootstrap.enabled -}}
{{- $components = append $components (dict "name" "node-bootstrap" "sa" "union-node-bootstrap") -}}
{{- end -}}
{{- if and .Values.clusterresourcesync.enabled (not (include "singleNamespace" .)) -}}
{{- $components = append $components (dict "name" "clusterresourcesync" "sa" (printf "union-%s" (include "clusterresourcesync.serviceAccountName" .))) -}}
{{- end -}}
{{- if include "serving.useVendoredGateway" . -}}
{{- $components = append $components (dict "name" "knative-controller" "sa" (include "knative.controller.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-webhook" "sa" (include "knative.webhook.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-autoscaler" "sa" (include "knative.autoscaler.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-activator" "sa" (include "knative.activator.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-kourier" "sa" (include "knative.kourier.serviceAccountName" .)) -}}
{{- end -}}
{{- toYaml $components -}}
{{- end -}}

{{- define "dataplane.rbac.slotOrder" -}}
- comp-ns-read
- comp-ns-write
- work-ns
- work-ns-cluster-read
- cluster-read
- cluster-write
{{- end -}}

{{- define "dataplane.rbac.slotSpec" -}}
comp-ns-read:
  pooled: false
  kind: comp
comp-ns-write:
  pooled: false
  kind: comp
work-ns:
  pooled: true
  kind: work
work-ns-cluster-read:
  pooled: false
  kind: work-cluster
cluster-read:
  pooled: false
  kind: cluster
cluster-write:
  pooled: false
  kind: cluster
{{- end -}}

{{- define "dataplane.rbac.verbs.read" -}}
- get
- list
- watch
{{- end -}}

{{- define "dataplane.rbac.verbs.write" -}}
- get
- list
- watch
- create
- update
- patch
- delete
- deletecollection
{{- end -}}

{{- define "dataplane.rbac.staticPosture" -}}
{{- if and .Values.namespaces.static .Values.namespaces.enabled -}}true{{- end -}}
{{- end -}}

{{- define "dataplane.rbac.slotRoleName" -}}
{{- if .component -}}
{{- printf "%s-%s-%s" .ctx.Release.Namespace .component .slot -}}
{{- else -}}
{{- printf "%s-%s" .ctx.Release.Namespace .slot -}}
{{- end -}}
{{- end -}}

{{- define "dataplane.rbac.emitSlot" -}}
{{- $ctx := .ctx -}}
{{- $rules := .rules | default list -}}
{{- if $rules -}}
{{- $spec := index (fromYaml (include "dataplane.rbac.slotSpec" $ctx)) .slot -}}
{{- $name := include "dataplane.rbac.slotRoleName" (dict "ctx" $ctx "slot" .slot "component" (.component | default "")) -}}
{{- $lowPriv := include "singleNamespace" $ctx -}}
{{- if and (eq $spec.kind "work-cluster") $lowPriv -}}
{{- else -}}
{{- $resolved := list -}}
{{- $allow := fromYamlArray (include "dataplane.rbac.verbs.write" $ctx) -}}
{{- if hasSuffix "-read" $.slot -}}
{{- $allow = fromYamlArray (include "dataplane.rbac.verbs.read" $ctx) -}}
{{- end -}}
{{- range $rule := $rules -}}
{{- if and (ne $spec.kind "work") (has "*" ($rule.apiGroups | default list)) -}}
{{- fail (printf "RBAC slot %q has a rule with apiGroups [\"*\"] (resources %v). Only the work-ns slot may name every API group. Name the groups this rule needs." $.slot $rule.resources) -}}
{{- end -}}
{{- if not $rule.verbs -}}
{{- fail (printf "RBAC slot %q requires a verbs key on every rule, and the rule for resources %v has none or an empty one. Name the verbs that rule needs; %q allows %v." $.slot $rule.resources $.slot $allow) -}}
{{- end -}}
{{- range $v := $rule.verbs -}}
{{- if not (has $v $allow) -}}
{{- fail (printf "RBAC slot %q names verb %q, which is not allowed here. %q allows %v. Wildcards, escalate and impersonate are never allowed on a declared rule, and the chart writes its own bind rule. A rule needing a write verb belongs in a write slot." $.slot $v $.slot $allow) -}}
{{- end -}}
{{- end -}}
{{- $resolved = append $resolved $rule -}}
{{- end -}}
{{- if and (eq .slot "cluster-write") (eq (.component | default "") "clusterresourcesync") -}}
{{- $resolved = concat $resolved (fromYamlArray (include "dataplane.rbac.provisionerBindRule" $ctx) | default list) -}}
{{- end -}}
{{- $isCluster := or (eq $spec.kind "cluster") (eq $spec.kind "work-cluster") -}}
{{- $roleKind := "Role" -}}
{{- if $isCluster -}}
{{- $roleKind = "ClusterRole" -}}
{{- else if and (eq $spec.kind "work") (not $lowPriv) -}}
{{- $roleKind = "ClusterRole" -}}
{{- end }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ $roleKind }}
metadata:
  name: {{ $name }}
  {{- if eq $roleKind "Role" }}
  namespace: {{ $ctx.Release.Namespace }}
  {{- end }}
rules:
  {{- toYaml $resolved | nindent 2 }}
{{- $subjects := list -}}
{{- range $sa := .subjects -}}
{{- $subjects = append $subjects (dict "kind" "ServiceAccount" "name" $sa "namespace" $ctx.Release.Namespace) -}}
{{- end }}
{{- if $isCluster }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $name }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $name }}
subjects:
  {{- toYaml $subjects | nindent 2 }}
{{- else if eq $spec.kind "comp" }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $name }}
subjects:
  {{- toYaml $subjects | nindent 2 }}
{{- else if $lowPriv }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $name }}
subjects:
  {{- toYaml $subjects | nindent 2 }}
{{- else if include "dataplane.rbac.staticPosture" $ctx }}
{{- range $ns := $ctx.Values.namespaces.static }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $name }}
subjects:
  {{- toYaml $subjects | nindent 2 }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "dataplane.rbac.taskPluginClusterReadRules" -}}
{{- $out := list -}}
{{- range $i, $rule := .Values.taskPluginClusterReadRules | default list -}}
{{- if not (kindIs "map" $rule) -}}
{{- fail (printf "taskPluginClusterReadRules[%d] is not a map. Each entry names apiGroups and resources, and optionally verbs." $i) -}}
{{- end -}}
{{- range $k, $_ := $rule -}}
{{- if not (has $k (list "apiGroups" "resources" "verbs")) -}}
{{- fail (printf "taskPluginClusterReadRules[%d] has key %q. Only apiGroups, resources and verbs are allowed: the grant is a cluster-wide read of whole resource types, so resourceNames and nonResourceURLs have no place in it." $i $k) -}}
{{- end -}}
{{- end -}}
{{- if or (not $rule.apiGroups) (not $rule.resources) -}}
{{- fail (printf "taskPluginClusterReadRules[%d] needs non-empty apiGroups and resources." $i) -}}
{{- end -}}
{{- range $f := list "apiGroups" "resources" "verbs" -}}
{{- range $v := (index $rule $f | default list) -}}
{{- if contains "*" (toString $v) -}}
{{- fail (printf "taskPluginClusterReadRules[%d].%s contains %q. Wildcards are not allowed here: this is a cluster-wide grant, and a wildcard would extend it to resource types installed after this render. Name the CRDs your plugins watch." $i $f $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $g := $rule.apiGroups -}}
{{- if or (not (contains "." (toString $g))) (has (toString $g) (list "rbac.authorization.k8s.io" "certificates.k8s.io")) -}}
{{- fail (printf "taskPluginClusterReadRules[%d].apiGroups names %q, a built-in Kubernetes group. This key is for the CRDs of CRD-backed task plugins, such as sparkoperator.k8s.io or ray.io; it grants cluster-wide reads, so built-in groups (the core group \"\", groups without a dot, rbac.authorization.k8s.io, certificates.k8s.io) are refused." $i $g) -}}
{{- end -}}
{{- end -}}
{{- $read := fromYamlArray (include "dataplane.rbac.verbs.read" $) -}}
{{- range $v := $rule.verbs | default list -}}
{{- if not (has $v $read) -}}
{{- fail (printf "taskPluginClusterReadRules[%d].verbs names %q. Only %v are allowed: the plugin's writes happen inside work namespaces, where the work-ns role already grants them." $i $v $read) -}}
{{- end -}}
{{- end -}}
{{- $out = append $out (dict "apiGroups" $rule.apiGroups "resources" $rule.resources "verbs" ($rule.verbs | default (list "list" "watch"))) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- define "dataplane.rbac.slotSubjects" -}}
{{- $ctx := .ctx -}}
{{- $slot := .slot -}}
{{- $out := list -}}
{{- range $c := fromYamlArray (include "dataplane.rbac.components" $ctx) -}}
{{- $decl := fromYaml (include (printf "dataplane.rbac.slots.%s" $c.name) $ctx) -}}
{{- if index $decl $slot -}}
{{- if not (has $c.sa $out) -}}
{{- $out = append $out $c.sa -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{- define "dataplane.rbac.provisionerBindRule" -}}
{{- if fromYamlArray (include "dataplane.rbac.slotSubjects" (dict "ctx" . "slot" "work-ns")) -}}
- apiGroups:
    - rbac.authorization.k8s.io
  resources:
    - clusterroles
  verbs:
    - bind
  resourceNames:
    - {{ include "dataplane.rbac.slotRoleName" (dict "ctx" . "slot" "work-ns" "component" "") }}
{{- end -}}
{{- end -}}

{{- define "dataplane.rbac.provisionerBindingTemplate" -}}
{{- $subjects := fromYamlArray (include "dataplane.rbac.slotSubjects" (dict "ctx" . "slot" "work-ns")) -}}
{{- if $subjects -}}
{{- $name := include "dataplane.rbac.slotRoleName" (dict "ctx" . "slot" "work-ns" "component" "") -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $name }}
  namespace: {{ `{{ namespace }}` }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $name }}
subjects:
{{- range $sa := $subjects }}
  - kind: ServiceAccount
    name: {{ $sa }}
    namespace: {{ $.Release.Namespace }}
{{- end }}
{{- end -}}
{{- end -}}
