{{/*
The enabled components and the ServiceAccount each runs as. Every other RBAC
helper ranges over this, so rules and binding subjects cannot drift apart.

Returns a YAML list of {name, sa} pairs. The order is fixed, which also fixes
emission order downstream.
*/}}
{{- define "dataplane.rbac.components" -}}
{{- $components := list -}}
{{- if .Values.executor.enabled -}}
{{- $components = append $components (dict "name" "executor" "sa" (include "executor.serviceAccountName" .)) -}}
{{- end -}}
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
{{- if and .Values.clusterresourcesync.enabled (not (include "singleNamespace" .)) -}}
{{- $components = append $components (dict "name" "clusterresourcesync" "sa" (printf "union-%s" (include "clusterresourcesync.serviceAccountName" .))) -}}
{{- end -}}
{{- toYaml $components -}}
{{- end -}}

{{/*
=============================================================================
SLOT MODEL

Grants are split by where they apply: the components namespace (the release
namespace, where union's own workloads run) versus the work namespaces (per
project/domain, where user tasks run).

  slot                  object       binding              low_privilege: true
  --------------------  -----------  -------------------  -------------------
  comp-ns-read          Role         RoleBinding, rel ns  unchanged
  comp-ns-write         Role         RoleBinding, rel ns  unchanged
  work-ns               ClusterRole  RoleBinding per ns   Role + RB, rel ns
  work-ns-cluster-read  ClusterRole  ClusterRoleBinding   empty, no fail
  cluster-read          ClusterRole  ClusterRoleBinding   must be empty
  cluster-write         ClusterRole  ClusterRoleBinding   must be empty

Under full privilege, work-ns is never bound in the release namespace. Under
low_privilege it is, because there the release namespace is the work namespace.

Pooling: pooled if granted by a RoleBinding, per-component if granted by a
ClusterRoleBinding. A RoleBinding is confined to one namespace, while a mistake
in a ClusterRoleBinding affects the whole cluster. So pooled slots get
emitter-owned verbs and cluster slots let the component name its own.
*/}}

{{/*
Emission order, fixed so the rendered manifest is stable.
*/}}
{{- define "dataplane.rbac.slotOrder" -}}
- comp-ns-read
- comp-ns-write
- work-ns
- work-ns-cluster-read
- cluster-read
- cluster-write
{{- end -}}

{{/*
Per-slot behavior. The objects and bindings each kind produces are in the table
above.

  pooled  true -> one shared role bound to every declaring SA
          false -> one role per declaring component
  kind    comp, work, cluster, work-cluster. A non-empty `cluster` slot under
          low_privilege fails the render (gate the component instead, as
          nodeobserver does). `work-cluster` emits nothing there.
  verbs   present -> emitter-owned; declarations must not carry a verbs key
          absent  -> component-supplied, checked against the allowlist
*/}}
{{- define "dataplane.rbac.slotSpec" -}}
comp-ns-read:
  pooled: true
  kind: comp
  verbs: read
comp-ns-write:
  pooled: true
  kind: comp
  verbs: write
work-ns:
  pooled: true
  kind: work
  verbs: write
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

{{/*
Emitter-owned verb sets for pooled slots. Write is a superset of read, so a
resource in a write slot need not also appear in the read slot. Wildcard verbs
are excluded: on `roles` a wildcard grants `escalate`, disabling RBAC's
escalation-prevention check, and on `serviceaccounts` it grants `impersonate`.
*/}}
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

{{/*
Verbs a cluster-slot declaration may name. Excludes wildcards, `escalate` and
`impersonate`, and `bind` (emitter-authored only, see dataplane.rbac.emitSlot).
*/}}
{{- define "dataplane.rbac.verbAllowlist" -}}
- get
- list
- watch
- create
- update
- patch
- delete
- deletecollection
{{- end -}}

{{/*
True ("true" or "") when the work namespaces are known at render time, so the
chart creates the bindings itself and clusterresourcesync needs no cluster-wide
grant. Four things key off this define and must move together: the per-namespace
RoleBindings, clusterresourcesync's cluster grant, `a_namespace` in its template
set, and the generated RoleBinding template. namespaces.create is not part of it;
clusterresourcesync holds no `namespaces` permission here either way.
*/}}
{{- define "dataplane.rbac.staticPosture" -}}
{{- if and .Values.namespaces.static .Values.namespaces.enabled -}}true{{- end -}}
{{- end -}}

{{/*
Role name for a slot. Namespace-qualified even for the namespaced kinds:
cluster-scoped names must be qualified, or two releases in different namespaces
overwrite each other's roles.

Args: dict with ctx, slot, component ("" for pooled slots).
*/}}
{{- define "dataplane.rbac.slotRoleName" -}}
{{- if .component -}}
{{- printf "%s-%s-%s" .ctx.Release.Namespace .component .slot -}}
{{- else -}}
{{- printf "%s-%s" .ctx.Release.Namespace .slot -}}
{{- end -}}
{{- end -}}

{{/*
Emit one slot's role and its bindings. Emits nothing when rules is empty.

Args: dict with
  ctx         root context
  slot        one of dataplane.rbac.slotOrder
  rules       {apiGroups, resources} maps for pooled slots, or
              {apiGroups, resources, verbs, resourceNames?} for cluster slots.
              Chart-derived and operator-supplied declarations look the same
              here, and both run the validation below.
  subjects    list of ServiceAccount names to bind
  component   component name for per-component slots; "" for pooled

There is no arg for the emitter's own `bind` rule. Such an arg would let a caller
aim an unvalidated rule at any slot, so the rule is constructed below instead.
*/}}
{{- define "dataplane.rbac.emitSlot" -}}
{{- $ctx := .ctx -}}
{{- $rules := .rules | default list -}}
{{- if $rules -}}
{{- $spec := index (fromYaml (include "dataplane.rbac.slotSpec" $ctx)) .slot -}}
{{- $name := include "dataplane.rbac.slotRoleName" (dict "ctx" $ctx "slot" .slot "component" (.component | default "")) -}}
{{- $lowPriv := include "singleNamespace" $ctx -}}
{{/*
Under low_privilege, limit-namespace makes these caches namespace-scoped and the
pooled work-ns Role already grants the same reads in the release namespace, so
work-cluster emits nothing rather than failing.
*/}}
{{- if and (eq $spec.kind "work-cluster") $lowPriv -}}
{{- else -}}
{{- $resolved := list -}}
{{- if $spec.verbs -}}
{{- $verbs := fromYamlArray (include (printf "dataplane.rbac.verbs.%s" $spec.verbs) $ctx) -}}
{{- range $rule := $rules -}}
{{- if $rule.verbs -}}
{{- fail (printf "RBAC slot %q sets the verbs itself, so its rules must not carry a verbs key, and this one has %v. Drop the key: the slot grants %v." $.slot $rule.verbs $verbs) -}}
{{- end -}}
{{- $resolved = append $resolved (merge (dict "verbs" $verbs) $rule) -}}
{{- end -}}
{{- else -}}
{{- $allow := fromYamlArray (include "dataplane.rbac.verbAllowlist" $ctx) -}}
{{/*
No `bind` exemption: it is never valid on a declared rule. The emitter's own
bind rule never passes through $rules, and is spliced into $resolved below.
*/}}
{{- range $rule := $rules -}}
{{- if not $rule.verbs -}}
{{- fail (printf "RBAC slot %q needs a verbs key on every rule, and the rule for resources %v has none. Add the verbs that rule needs." $.slot $rule.resources) -}}
{{- end -}}
{{- range $v := $rule.verbs -}}
{{- if not (has $v $allow) -}}
{{- fail (printf "RBAC slot %q names verb %q, which is not allowed here. Use one of %v. Wildcards, escalate and impersonate are never allowed on a declared rule, and the chart writes its own bind rule." $.slot $v $allow) -}}
{{- end -}}
{{- end -}}
{{- $resolved = append $resolved $rule -}}
{{- end -}}
{{- end -}}
{{- if and (eq .slot "cluster-write") (eq (.component | default "") "clusterresourcesync") -}}
{{/*
provisionerBindRule returns nothing unless the work namespaces are created at
runtime, and in that case $rules is never empty for this slot, so nothing is
lost by sitting inside the `if $rules` gate above.
*/}}
{{- $resolved = concat $resolved (fromYamlArray (include "dataplane.rbac.provisionerBindRule" $ctx) | default list) -}}
{{- end -}}
{{/*
`work` is a ClusterRole under full privilege only so its rules are defined once
for all namespaces. Per-namespace RoleBindings are its only bindings, so it
grants nothing cluster-wide.
*/}}
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
{{/* The release namespace is the work namespace, so work-ns binds here. */}}
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
{{/*
One RoleBinding per known work namespace. Referencing a ClusterRole from a
RoleBinding scopes the grant to that namespace. When the namespaces are instead
created at runtime, nothing is emitted here and
dataplane.rbac.provisionerBindingTemplate handles the binding.
*/}}
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

{{/*
ServiceAccount names that declared into a slot, in first-seen component order.
Only enabled components contribute.

Args: dict with ctx, slot. Returns a YAML list of ServiceAccount names.
*/}}
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

{{/*
Emitter-authored `bind` rule letting clusterresourcesync bind the pooled work-ns
ClusterRole in namespaces it provisions. Creating a RoleBinding needs either
every permission in the referenced role or `bind` on it. resourceNames confines
this to the one chart-authored role, so clusterresourcesync never holds that
role's permissions and cannot substitute a stronger role.

Returns a one-rule YAML list, or nothing when the chart binds work-ns itself.
*/}}
{{- define "dataplane.rbac.provisionerBindRule" -}}
{{- if not (include "dataplane.rbac.staticPosture" .) -}}
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

{{/*
The clusterresource-template entry creating the work-ns RoleBinding in each
namespace clusterresourcesync provisions.

Keyed `ab_` so it sorts between a_namespace and b_default_service_account (`_`
is 0x5F, `b` is 0x62). Keep that order: work-ns is what gives clusterresourcesync
access to a new namespace, so this binding must be applied before the
ServiceAccount and ResourceQuota it then creates, or new projects stall until the
next sync.

`{{ namespace }}` is clusterresourcesync's own placeholder, substituted at
provision time, so it is passed through literally.
*/}}
{{- define "dataplane.rbac.provisionerBindingTemplate" -}}
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
{{- range $sa := fromYamlArray (include "dataplane.rbac.slotSubjects" (dict "ctx" . "slot" "work-ns")) }}
  - kind: ServiceAccount
    name: {{ $sa }}
    namespace: {{ $.Release.Namespace }}
{{- end }}
{{- end -}}
