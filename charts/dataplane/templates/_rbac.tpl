{{/*
The enabled components and the ServiceAccount each runs as. Every other RBAC
helper ranges over this, so rules and binding subjects cannot drift apart.

Returns a YAML list of {name, sa} pairs. The order is fixed, which also fixes
emission order downstream.

A component joins this list once it declares dataplane.rbac.slots.<name>. Every
component with general RBAC now does, so none still owns a hand-written Role for
its release-namespace, work-namespace or cluster-scope grants. That includes the
app-serving binaries, whose vendored Knative Serving and Kourier RBAC this chart
no longer carries. imagebuilder and the Kourier *gateway* -- the Envoy data plane,
not the net-kourier controller that declares knative-kourier below -- are the two
that declare no slots: their only grant is an OpenShift SCC `use`, which is not a
slot destination.

That is not the same as "the chart writes no RBAC outside this file", and the
difference matters when auditing. Slots are organized by destination, and three
kinds of grant have no destination here:

  a namespace the operator names   proxy's Secret Role in proxy.secretsNamespace,
                                   the operator's secrets-watcher Role in the
                                   control-plane namespace. The emitter binds
                                   only in the release namespace and the work
                                   namespaces, so neither fits.
  a role with no rules to carry    clusterresourcesync's system:auth-delegator
                                   ClusterRoleBinding references a built-in role.
  objects that outlive nothing     the pre-upgrade hooks in common/ and webhook/,
                                   which carry hook-delete-policy.
  a verb with no slot              the OpenShift SCC Roles for imagebuilder and the
                                   Kourier gateway, both via openshift.sccRbac.
                                   `use` on a named SecurityContextConstraints is
                                   not one of the emitter's verb sets.

Also outside: third-party subchart RBAC this chart authors
(templates/prometheus/, templates/ingress-nginx/).

If you are auditing, do not enumerate by grepping for `kind: Role`. Some templates
emit RBAC only through a helper and contain no such literal -- inspect the callers
of openshift.sccRbac and of dataplane.rbac.emitSlot as well. Nor is rendering the
test fixtures sufficient: the Kourier SCC Role appears in none of them, because it
needs apps.enabled and kourierGatewayScc.enabled together. Both blind spots have
produced a wrong inventory in this file before.
*/}}
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
{{/*
The one entry whose gate is not just an enabled key: clusterresourcesync's own
templates render only outside singleNamespace, so joining the registry under
low_privilege would emit RBAC for a ServiceAccount that does not exist. Its
subject is `union-` prefixed because the ServiceAccount is, unlike every other
component here.
*/}}
{{- if and .Values.clusterresourcesync.enabled (not (include "singleNamespace" .)) -}}
{{- $components = append $components (dict "name" "clusterresourcesync" "sa" (printf "union-%s" (include "clusterresourcesync.serviceAccountName" .))) -}}
{{- end -}}
{{/*
The app-serving binaries. Their slot declarations live beside their
ServiceAccounts in gateway/serviceaccounts.yaml, and they join the registry
under the same condition every other gateway/ template renders under. The six
app-serving workloads map onto five entries: autoscaler-hpa runs the same
reconciler as autoscaler under a different PodAutoscaler class, shares its
ServiceAccount, and declares no slots of its own.
*/}}
{{- if include "zeroTrustApps.enabled" . -}}
{{- $components = append $components (dict "name" "knative-controller" "sa" (include "knative.controller.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-webhook" "sa" (include "knative.webhook.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-autoscaler" "sa" (include "knative.autoscaler.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-activator" "sa" (include "knative.activator.serviceAccountName" .)) -}}
{{- $components = append $components (dict "name" "knative-kourier" "sa" (include "knative.kourier.serviceAccountName" .)) -}}
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
  cluster-read          ClusterRole  ClusterRoleBinding   unchanged
  cluster-write         ClusterRole  ClusterRoleBinding   unchanged

Under full privilege, work-ns is never bound in the release namespace. Under
low_privilege it is, because there the release namespace is the work namespace.

Pooling: pooled if granted by a RoleBinding, per-component if granted by a
ClusterRoleBinding. A RoleBinding is confined to one namespace, while a mistake in a
ClusterRoleBinding affects the whole cluster.

Every rule names its own verbs, in every slot. In a pooled slot that makes the
declaration a statement of what one component needs, not a bound on what it gets: the
role is the union of every declarer's rules and RBAC unions them, so a resource two
components name is granted at the union of their verbs to both. Only the rendered role
is authoritative about grant. See docs/rbac-union.md.

An earlier version of this file had the emitter own the verbs in pooled slots, on the
reasoning that one component should not set verbs for everyone sharing the role. That
protection was always partial -- the resource axis was never guarded, and a wildcard rule
widens the shared role for every declarer regardless of verbs -- while the cost was that
no rule in a pooled slot could ask for less than the whole set.
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
  kind    comp, work, cluster, work-cluster. A `cluster` slot is emitted as a
          ClusterRole plus ClusterRoleBinding in both privilege modes: what it
          carries is cluster-scoped in both, so low_privilege cannot narrow it
          and refusing to render it only moves the failure to runtime.
          `work-cluster` emits nothing under low_privilege.
*/}}
{{- define "dataplane.rbac.slotSpec" -}}
comp-ns-read:
  pooled: true
  kind: comp
comp-ns-write:
  pooled: true
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

{{/*
The two verb allowlists. `write` is the base set every slot admits; `read` is the
narrowing applied to slots whose name ends in -read. Neither contains a wildcard: on
`roles` a wildcard verb grants `escalate`, disabling RBAC's escalation-prevention check,
and on `serviceaccounts` it grants `impersonate`. `escalate`, `impersonate` and `bind`
are likewise absent -- the emitter authors its own bind rule, which never passes through
a declaration.

Write is a superset of read, so a slot admitting writes admits reads too. A rule may name
any subset of its slot's allowlist; nothing requires it to use all of them.
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
True ("true" or "") when some work namespaces are known at render time, so the
chart can create their bindings itself.

This is not the complement of runtime provisioning, and nothing else may treat it
as one. namespaces.static is a pre-seeded subset: clusterresourcesync still
creates a namespace per project/domain as projects are registered, whatever this
returns. So the provisioner's `bind` rule and the RoleBinding handed to it are
emitted in both postures -- withholding them here would leave every namespace
registered after install with no binding and nothing allowed to make one, which
renders clean and fails at first task execution. Only the per-namespace
RoleBindings in dataplane.rbac.emitSlot key off this.
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
{{/*
Every rule names its own verbs. The allowlist comes from the slot's name: a slot whose
name ends in -read admits only reads, everything else admits the base set. The base set
is the ceiling in both cases -- it excludes `*`, `escalate`, `impersonate` and `bind`,
which is what stops a declaration from disabling RBAC's escalation check or minting
tokens, and that ceiling applies to work-ns exactly as it does to the rest.

Deriving this from the name rather than a slotSpec key means the two cannot drift: a
slot named -read cannot be given a write allowlist by mistake.
*/}}
{{- $allow := fromYamlArray (include "dataplane.rbac.verbs.write" $ctx) -}}
{{- if hasSuffix "-read" $.slot -}}
{{- $allow = fromYamlArray (include "dataplane.rbac.verbs.read" $ctx) -}}
{{- end -}}
{{- range $rule := $rules -}}
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
{{/*
Sitting inside the `if $rules` gate above costs nothing: clusterresourcesync's
own declaration always puts the provisioning rules in this slot, so whenever
this component is in the registry at all the slot has rules to carry the bind
rule alongside.
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
RoleBinding scopes the grant to that namespace.

This covers namespaces.static and nothing else. Namespaces created at runtime are
not known here, so their bindings come from the provisioner instead:
dataplane.rbac.provisionerBindingTemplate renders exactly that object and
dataplane.rbac.provisionerBindRule the `bind` grant its creator needs. Both are
wired to clusterresourcesync and are emitted in both postures, because a static
list does not stop projects being registered later; anything else provisioning
work namespaces owes the same two things itself.
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

Emitted whether or not namespaces.static pre-seeds some namespaces: static is a
subset, and the namespaces registered after install are exactly the ones only the
provisioner can reach.

Returns a one-rule YAML list, or nothing when no component declares work-ns and
there is therefore no pooled role to bind.
*/}}
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

{{/*
The clusterresource-template entry creating the work-ns RoleBinding in each
namespace clusterresourcesync provisions. Its consumer is
clusterresourcesync/configmap.yaml, which keys it `ab_work_ns_binding` so it sorts
between a_namespace and b_default_service_account (`_` is 0x5F, `b` is 0x62).

That ordering is real, not decorative: the sync lists the mounted template directory
with a call that returns entries sorted by filename and applies them sequentially in
one pass, so the key decides when this object is created relative to the others. Keep
it directly after the Namespace, so a work namespace is reachable by union's
components from the moment it exists rather than at the end of the pass.

What this ordering is NOT for: clusterresourcesync does not need this binding to
create the ServiceAccount and ResourceQuota that follow it. Authority for those comes
from its own ClusterRole, which grants them cluster-wide at the default
clusterRoleRules, and a template that fails does not abort the rest of the pass. So
reordering this key delays when a new namespace becomes usable; it does not break
provisioning. Recovery from a failed apply is not stated here on purpose: upstream
caches the template checksum per namespace and file rather than per execution target,
so with several targets a success on one can suppress the retry on another.

Emitted alongside dataplane.rbac.provisionerBindRule and under the same condition:
the two halves are one grant, and either alone is useless. Emitted even when
namespaces.static pre-seeds some namespaces, because the chart's own RoleBindings
cover only that list -- a project registered after install gets its namespace from
the provisioner, so it gets its binding from here or from nowhere. Where both
apply to the same namespace the two produce the identical object.

Returns nothing when no component declares work-ns: there is then no pooled role
for the RoleBinding to reference.

`{{ namespace }}` is clusterresourcesync's own placeholder, substituted at
provision time, so it is passed through literally. That is also why the ConfigMap
carrying this does not `tpl` its entries.
*/}}
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
