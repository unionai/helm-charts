{{/*
The single enumeration of which components are enabled and which ServiceAccount
each runs as. Every other RBAC helper in this chart -- common/rbac.yaml's
per-slot rule gathering, and dataplane.rbac.slotSubjects' naming below --
ranges over THIS, not a copy of it. A component that appears in one
enumeration and not the other is exactly the failure this enumeration exists
to prevent: its ServiceAccount either gets rules with no name to bind, or a
name with no rules, and either way the mismatch is invisible at render time --
it shows up as a runtime Forbidden in a provisioner, not a template error.

Returns a YAML list of {name, sa} pairs, one per enabled component, in a fixed
order (this fixes emission order downstream: first-seen-sa wins its position).
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

RBAC is partitioned on WHERE a grant applies, not on what kind of resource it
names. Two destinations want different things: the components namespace (the
release namespace, where union's own workloads run) and the work namespaces
(per-project/domain, where user tasks, apps and builds run).

  slot                   object        binding              low_privilege: true
  ---------------------  ------------  -------------------  -------------------
  comp-ns-read           Role          RoleBinding, rel ns  unchanged
  comp-ns-write          Role          RoleBinding, rel ns  unchanged
  work-ns                ClusterRole   RoleBinding per ns   Role + RB, rel ns
  work-ns-read-unscoped  ClusterRole   ClusterRoleBinding   must be empty
  cluster-read           ClusterRole   ClusterRoleBinding   must be empty
  cluster-write          ClusterRole   ClusterRoleBinding   must be empty

work-ns is NEVER bound in the release namespace under full privilege. That is
the entire split. Under low_privilege it is, because there the release
namespace IS the work namespace.

POOLING RULE: pooled if conveyed by a RoleBinding, per-component if conveyed by
a ClusterRoleBinding. Blast radius is bounded by a namespace in the first case
and unbounded in the second. Precision buys nothing where grants merge and a
lot where they are isolated and cluster-wide -- which is also why pooled slots
have emitter-owned verbs and cluster slots let the component name its own.
*/}}

{{/*
Emission order. Fixed so the rendered manifest is stable across renders.
*/}}
{{- define "dataplane.rbac.slotOrder" -}}
- comp-ns-read
- comp-ns-write
- work-ns
- work-ns-read-unscoped
- cluster-read
- cluster-write
{{- end -}}

{{/*
Per-slot behavior.

  pooled  true  -> one shared role, subjects are every SA that declared into it
          false -> one role per declaring component
  kind    comp    -> Role in the release namespace, RoleBinding there
          work    -> ClusterRole + RoleBinding per work namespace
                     (Role + RoleBinding in the release namespace under
                     low_privilege, where there are no separate work namespaces)
          cluster -> ClusterRole + ClusterRoleBinding
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
work-ns-read-unscoped:
  pooled: false
  kind: cluster
cluster-read:
  pooled: false
  kind: cluster
cluster-write:
  pooled: false
  kind: cluster
{{- end -}}

{{/*
Emitter-owned verb sets for pooled slots.

Write is a SUPERSET of read: a controller that creates a Pod has to get it back
to check status. That means a component naming a resource in a write slot need
not also name it in the read slot, which deletes the near-duplicate declaration
lists the old bucket model required. A read slot now means "reads this and
never writes it".

`*` appears nowhere. It was never chosen -- it arrived verbatim from upstream
Flyte's flyteadmin ClusterRole in 18eb2ead and was carried forward unexamined.
On `roles` it conveys `escalate`, which switches off RBAC's own
escalation-prevention check; on `serviceaccounts` it conveys `impersonate`.
Nothing here needs either.
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
Verbs a cluster-slot declaration may name. Excludes `*` (see above), `escalate`
and `impersonate` (never needed), and `bind` (emitter-authored only, see
dataplane.rbac.emitSlot).
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
True when the work namespaces are known at render time, so this chart creates
the bindings itself and clusterresourcesync needs no cluster-wide grant.

THE organizing condition. Four things key off it and must move together:
whether Helm emits the per-namespace RoleBindings, whether clusterresourcesync
gets a cluster grant, whether `a_namespace` stays in its template set, and
whether the generated RoleBinding template is emitted at all. They are read
from this one define rather than spelled out separately, because three copies
that happen to agree is how the old model grew its recursion.

namespaces.create is deliberately NOT part of this. clusterresourcesync holds
no `namespaces` permission in this posture regardless of who created the
objects, so a pre-created namespace is no more reconcilable by it than a
chart-created one.

Returns "true" or "".
*/}}
{{- define "dataplane.rbac.staticPosture" -}}
{{- if and .Values.namespaces.static .Values.namespaces.enabled -}}true{{- end -}}
{{- end -}}

{{/*
Role name for a slot.

Namespace-qualified for EVERY slot, including the namespaced ones: a single
naming rule is easier to check mechanically than "qualify these, not those",
and cluster-scoped names MUST be qualified or two releases in different
namespaces on one cluster silently overwrite each other's roles.

Args: dict with ctx, slot, and component (empty string for pooled slots).
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
  rules       list of {apiGroups, resources} maps for pooled slots, or
              {apiGroups, resources, verbs, resourceNames?} for cluster slots
  subjects    list of ServiceAccount names to bind
  component   component name for per-component slots; "" for pooled
*/}}
{{- define "dataplane.rbac.emitSlot" -}}
{{- $ctx := .ctx -}}
{{- $rules := .rules | default list -}}
{{- if $rules -}}
{{- $spec := index (fromYaml (include "dataplane.rbac.slotSpec" $ctx)) .slot -}}
{{- $name := include "dataplane.rbac.slotRoleName" (dict "ctx" $ctx "slot" .slot "component" (.component | default "")) -}}
{{- $lowPriv := include "singleNamespace" $ctx -}}
{{/*
A cluster-bound slot cannot be conveyed by any namespaced Role, so under
low_privilege the COMPONENT must be gated rather than its rules degraded. A
namespaced Role naming a cluster-scoped resource is accepted by the API server
and simply never matches -- silent, which is why this fails loudly.
*/}}
{{- if and (eq $spec.kind "cluster") $lowPriv -}}
{{- fail (printf "RBAC slot %q is non-empty under low_privilege: true. Cluster-scoped grants cannot be conveyed by a namespaced Role. Gate the component instead of degrading its rules." .slot) -}}
{{- end -}}
{{/*
Resolve the verbs. Pooled slots take the emitter's set; cluster slots take the
component's, validated against the allowlist.
*/}}
{{- $resolved := list -}}
{{- if $spec.verbs -}}
{{- $verbs := fromYamlArray (include (printf "dataplane.rbac.verbs.%s" $spec.verbs) $ctx) -}}
{{- range $rule := $rules -}}
{{- if $rule.verbs -}}
{{- fail (printf "RBAC slot %q is emitter-owned: its declarations must not carry a verbs key (found %v). Remove it; the slot supplies %v." $.slot $rule.verbs $verbs) -}}
{{- end -}}
{{- $resolved = append $resolved (merge (dict "verbs" $verbs) $rule) -}}
{{- end -}}
{{- else -}}
{{- $allow := fromYamlArray (include "dataplane.rbac.verbAllowlist" $ctx) -}}
{{/*
The one rule shape allowed to carry `bind`: apiGroups/resources/resourceNames
naming exactly the work-ns ClusterRole this chart authors, computed here
rather than accepted as an argument. `bind is emitter-authored only` is
enforced by this structural match, not by trusting the caller -- nothing a
component declares can produce this exact resourceNames value, because it is
this chart's own release-namespace-qualified role name, not an operator- or
component-supplied string. See dataplane.rbac.provisionerBindRule, the only
producer of a rule this shape.
*/}}
{{- $workNsRoleName := include "dataplane.rbac.slotRoleName" (dict "ctx" $ctx "slot" "work-ns" "component" "") -}}
{{- range $rule := $rules -}}
{{- if not $rule.verbs -}}
{{- fail (printf "RBAC slot %q requires an explicit verbs list on every rule (resources: %v)." $.slot $rule.resources) -}}
{{- end -}}
{{- $isBindRule := and (deepEqual ($rule.resources | default list) (list "clusterroles")) (deepEqual ($rule.resourceNames | default list) (list $workNsRoleName)) -}}
{{- range $v := $rule.verbs -}}
{{- if not (or (has $v $allow) (and (eq $v "bind") $isBindRule)) -}}
{{- fail (printf "RBAC slot %q names verb %q, which is not in the allowlist %v. Wildcards, escalate and impersonate are never permitted; bind is allowed only on a rule naming exactly resources: [clusterroles], resourceNames: [%s]." $.slot $v $allow $workNsRoleName) -}}
{{- end -}}
{{- end -}}
{{- $resolved = append $resolved $rule -}}
{{- end -}}
{{- end -}}
{{/*
Object kind. `work` is a ClusterRole under full privilege purely so its rules
are defined once instead of duplicated across N namespaces -- it is bound ONLY
by per-namespace RoleBindings, so it grants nothing cluster-wide.
*/}}
{{- $isCluster := eq $spec.kind "cluster" -}}
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
{{/*
Single-namespace mode: the release namespace IS the work namespace, so the
work-ns Role binds here.
*/}}
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
Static posture: one RoleBinding per known work namespace. A RoleBinding may
reference a ClusterRole; the grant is then scoped to the RoleBinding's own
namespace. That is the mechanism the whole model rests on -- rules defined
once, no cluster-wide reach implied, every namespace named explicitly.

In the runtime posture nothing is emitted here at all: clusterresourcesync
creates the binding per namespace it provisions, from the template
dataplane.rbac.provisionerBindingTemplate generates.
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

{{/*
ServiceAccount names that declared into a slot, in first-seen component order.

A ServiceAccount is bound to a slot iff some ENABLED component running as it
declared into that slot. nodeobserver declares only cluster slots, so it is not
a subject of work-ns.

Args: dict with ctx, slot.
Returns a YAML list of ServiceAccount names.
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
The `bind` rule clusterresourcesync needs to create RoleBindings for the pooled
work-ns ClusterRole in namespaces it provisions.

EMITTER-AUTHORED, not declared. Creating a RoleBinding requires either every
permission in the referenced role, or `bind` on that role. This is the second,
confined by resourceNames to one role this chart authored -- so the provisioner
can hand out work-ns without ever holding that role's own reach itself, and
cannot invent a more
powerful role and grant that instead. Its ceiling is what union components
already have.

Under pooled slots the target is a single constant, which is why this no longer
needs deriving from the rendered role set -- and why the recursion break that
derivation required is gone.

Returns a YAML list with one rule, or nothing when the chart binds work-ns
itself.
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
The clusterresource-template entry that creates the work-ns RoleBinding in each
namespace clusterresourcesync provisions.

Keyed `ab_` so it sorts between a_namespace and b_default_service_account (`_`
is 0x5F, `b` is 0x62). The ORDER IS LOAD-BEARING and inverted from the old
model: clusterresourcesync now reaches a new namespace THROUGH work-ns, so the
binding must exist before the ServiceAccount and ResourceQuota it then creates.
Applied last, every new project would stall until the following sync -- five
minutes at the default refreshInterval.

The old d_ keys also carried 00/10 phase prefixes to stop pod-creators being
bound before the webhook. With one pooled binding that window is
unconstructible, not merely averted, and the prefixes are gone.

`{{ namespace }}` is clusterresourcesync's own placeholder, substituted per
project/domain at provision time, so it is passed through literally.
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
