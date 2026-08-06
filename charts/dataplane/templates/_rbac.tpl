{{/*
RBAC emission, partitioned on two axes: the scope of the resource types a rule
names (namespaced vs cluster-scoped), and the verb class (read vs write).

A component declares four buckets. The emitter decides the object kind and the
binding kind, which is the part that must not be duplicated per component --
getting it wrong is silent, because a namespaced Role naming a cluster-scoped
resource is accepted by the API server and simply never matches.

  bucket         low_privilege: true   low_privilege: false   bound by
  -------------  --------------------  ---------------------  ---------------
  ns-read        Role                  ClusterRole            RoleBinding
  ns-write       Role                  ClusterRole            RoleBinding
  cluster-read   must not exist        ClusterRole            ClusterRoleBinding
  cluster-write  must not exist        ClusterRole            ClusterRoleBinding

The ns-* ClusterRoles under full privilege exist ONLY so their rules are defined
once rather than duplicated across N task namespaces. They are never referenced
by a ClusterRoleBinding, so they grant nothing cluster-wide.

A component whose cluster-* bucket is non-empty under low_privilege is a bug in
that component's gating, not something to paper over here -- see the gating
framework in the RBAC scope-split spec, section 6. The emitter fails loudly.
*/}}

{{/*
Role name for a bucket. Namespace-qualified for every bucket, including the
namespaced ones: a single naming rule is easier to check mechanically than
"qualify these, not those", and cluster-scoped names MUST be qualified or two
releases in different namespaces on one cluster overwrite each other.

Args: dict with ctx, identity, bucket.
*/}}
{{- define "dataplane.rbac.roleName" -}}
{{- printf "%s-%s-%s" .ctx.Release.Namespace .identity .bucket -}}
{{- end -}}

{{/*
True when a bucket name denotes cluster-scoped resource types.
*/}}
{{- define "dataplane.rbac.isClusterBucket" -}}
{{- if hasPrefix "cluster-" . -}}true{{- end -}}
{{- end -}}

{{/*
Emit one bucket's role and binding. Emits nothing when rules is empty.

Args: dict with
  ctx             root context
  identity        the ServiceAccount-derived name segment
  bucket          one of ns-read, ns-write, cluster-read, cluster-write
  rules           list of rule maps, already partitioned by the caller
  serviceAccount  name of the ServiceAccount to bind
  skipReleaseNamespaceBinding  optional, default false. NS BUCKETS ONLY (ignored
                  for cluster-read/cluster-write, where the primary binding is
                  the only grant there is). When true, omits the release-namespace
                  RoleBinding that this function otherwise always emits for a
                  namespaced bucket -- see the comment at its emission site
                  below for why a caller would want that, and why it must stay
                  a narrow, explicit opt-out rather than a new default.
*/}}
{{- define "dataplane.rbac.emitBucket" -}}
{{- $rules := .rules | default list -}}
{{- if $rules -}}
{{- if and .ctx.Values.low_privilege (not .ctx.Values.rbac.clusterWideBindings) -}}
{{- fail "rbac.clusterWideBindings: false has no meaning under low_privilege: true. In single-namespace mode there are no task namespaces and nothing is bound cluster-wide, so setting this changes nothing -- it reads as a hardening step that did not happen. Remove the setting, or set low_privilege: false if you intended the multi-namespace posture." -}}
{{- end -}}
{{- $isCluster := include "dataplane.rbac.isClusterBucket" .bucket -}}
{{- $name := include "dataplane.rbac.roleName" (dict "ctx" .ctx "identity" .identity "bucket" .bucket) -}}
{{- if and $isCluster .ctx.Values.low_privilege -}}
{{- fail (printf "RBAC bucket %q for %q is non-empty under low_privilege: true. Cluster-scoped grants cannot be conveyed by any namespaced Role, so the COMPONENT must be gated rather than its rules degraded. See the gating framework in docs/superpowers/specs/2026-08-04-dataplane-rbac-scope-split-design.md section 6." .bucket .identity) -}}
{{- end -}}
{{/*
Only meaningful for a namespaced bucket -- see the flag's doc comment above
and the comment at its use below. `and` short-circuits, but spelling out
"not cluster" here (rather than relying on the caller to never pass the flag
for a cluster bucket) means a future cluster-bucket caller that passes it by
mistake gets a no-op, not a dropped ClusterRoleBinding.
*/}}
{{- $skipReleaseNamespaceBinding := and (not $isCluster) .skipReleaseNamespaceBinding -}}
{{/*
Resolve the object kind once and reuse it for both the namespaced-object kind
and the decision to emit metadata.namespace. Both must key off the same value:
namespace: belongs on the object iff its kind is Role, and kind is Role iff
"dataplane.rbacKind" says so (it wraps singleNamespace, i.e. low_privilege) --
not because low_privilege happens to agree today. Testing low_privilege
directly here would silently drift out of step if rbacKind is ever changed to
key on something else, producing a namespace-less Role or a namespaced
ClusterRole with no error. Do not "simplify" this back to a low_privilege test.
*/}}
{{/*
The action below deliberately does NOT chomp its trailing newline, so every
emitted block starts with one. Callers invoke this with `{{- include ... }}`,
which strips the whitespace in front of the call; without the newline here two
consecutive buckets render as `namespace: union---`, splicing the document
separator onto the previous line and silently corrupting the manifest stream.
It sits inside `if $rules` so an empty bucket still emits nothing at all.
*/}}
{{- $nsRoleKind := include "dataplane.rbacKind" .ctx }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ if $isCluster }}ClusterRole{{ else }}{{ $nsRoleKind }}{{ end }}
metadata:
  name: {{ $name }}
  {{- if not $isCluster }}
  {{- if eq $nsRoleKind "Role" }}
  namespace: {{ .ctx.Release.Namespace }}
  {{- end }}
  {{- end }}
rules:
  {{- toYaml $rules | nindent 2 }}
{{- if not $skipReleaseNamespaceBinding }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ if $isCluster }}ClusterRoleBinding{{ else }}RoleBinding{{ end }}
metadata:
  name: {{ $name }}
  {{- if not $isCluster }}
  namespace: {{ .ctx.Release.Namespace }}
  {{- end }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: {{ if $isCluster }}ClusterRole{{ else }}{{ $nsRoleKind }}{{ end }}
  name: {{ $name }}
subjects:
  - kind: ServiceAccount
    name: {{ .serviceAccount }}
    namespace: {{ .ctx.Release.Namespace }}
{{- else }}
{{/*
skipReleaseNamespaceBinding is set: the caller does not want this identity to
hold a grant in the release namespace at all, only in the namespaces named by
the per-namespaces.managed loop below. Today the only caller is
clusterresourcesync's constrained posture (see
clusterresourcesync/serviceaccount.yaml): it provisions OTHER namespaces, and
its reach there is meant to be exactly the enumerated task namespaces and
nothing else -- gaining release-namespace access as a side effect of this
function's usual behavior would be an unrequested, unreviewed grant. This is
a narrow, explicit per-call opt-out, not a reversal of the policy below: the
release-namespace RoleBinding stays the default for every other ns-* bucket,
and the deliberate overlap with the cluster-wide binding it describes is
unaffected.
*/}}
{{- end }}
{{- if and (not $isCluster) (not .ctx.Values.low_privilege) }}
{{/*
One RoleBinding per enumerated task namespace, binding the same ns-* role.

A RoleBinding may reference a ClusterRole: the grant is then scoped to the
RoleBinding's own namespace. That is the whole mechanism this posture rests on
-- the rules are defined once, cluster-wide reach is not implied, and each
namespace is named explicitly.

Emitted whenever namespaces.managed is non-empty AND namespaces.enabled is
true, independently of rbac.clusterWideBindings, so that enumerating
namespaces and dropping the cluster-wide binding are separate steps an
operator can take in either order.

namespaces.enabled is load-bearing here, not just for Namespace creation: it
is the chart's only signal that the namespaces named by namespaces.managed
actually exist (or will, because the chart itself is creating them a few
lines away in common/namespaces.yaml). Without this gate, a bare
low_privilege: false install -- namespaces.managed at its non-empty default,
namespaces.enabled at its default false -- would emit RoleBindings into six
namespaces nothing has created, and a fresh install or ArgoCD sync would fail
with "namespaces <name> not found" before clusterresourcesync ever ran. See
RELEASE.md.
*/}}
{{- if .ctx.Values.namespaces.enabled }}
{{- range $ns := .ctx.Values.namespaces.managed }}
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
  - kind: ServiceAccount
    name: {{ $.serviceAccount }}
    namespace: {{ $.ctx.Release.Namespace }}
{{- end }}
{{- end }}
{{- end }}
{{- if and (not $isCluster) (not .ctx.Values.low_privilege) .ctx.Values.rbac.clusterWideBindings }}
{{/*
Cluster-wide binding for a NAMESPACED bucket.

This is the grant that reaches task namespaces. They are created at runtime, so
the chart cannot enumerate them and cannot emit a RoleBinding per namespace for
a set it does not know -- which is why the ns-* ClusterRole is bound
cluster-wide rather than per namespace by default.

It is emitted IN ADDITION TO the release-namespace RoleBinding above, never
instead of it. The overlap is deliberate: it means setting
rbac.clusterWideBindings: false is a pure removal, with the narrower bindings
already in place, so there is no window in which a workload holds neither.
(skipReleaseNamespaceBinding callers are the one narrow exception to "above":
they never had a release-namespace RoleBinding to remove, by their own
request -- see that flag's doc comment. This paragraph's "pure removal"
guarantee is otherwise unchanged.)

Dropping this without something creating per-namespace RoleBindings leaves
union workloads with no reach into task namespaces at all. That failure is
loud (Forbidden, named SA and verb, in propeller logs) but DELAYED -- it
appears at the first task execution, not at deploy.
*/}}
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
  - kind: ServiceAccount
    name: {{ .serviceAccount }}
    namespace: {{ .ctx.Release.Namespace }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
The single enumeration of which components are enabled and which ServiceAccount
each runs as. Every other RBAC helper in this chart -- common/rbac.yaml's
per-component bucket-content gathering, and dataplane.rbac.identities' naming
below -- ranges over THIS, not a copy of it. A component that appears in one
enumeration and not the other is exactly the failure this task exists to
prevent: its ServiceAccount either gets rules with no name to bind
(dataplane.rbac.identities has no entry for it, so bucketRoleNames can't name
its role) or a name with no rules (the reverse), and either way the mismatch is
invisible at render time -- it shows up as a runtime Forbidden in a provisioner,
not a template error.

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
{{/*
clusterresourcesync drops OUT of this enumeration in the constrained posture,
where its ns-write bucket is emitted directly by
clusterresourcesync/serviceaccount.yaml instead of through the grouping in
common/rbac.yaml.

Leaving it in produced a duplicate ClusterRole whenever another enabled
component resolved to the same ServiceAccount name. It is appended LAST here, so
dataplane.rbac.identities (last writer wins) mapped that shared name to
`clusterresourcesync`; the grouped emission then rendered a SECOND
{release}-clusterresourcesync-ns-write carrying the OTHER component's rules and
no `bind`. Two same-named ClusterRoles in one release is
last-one-applied-wins, and the loser was the provisioner's grant -- a clean
render, and clusterresourcesync silently unable to create task-namespace
RoleBindings.

Removing it from the enumeration makes that state unconstructible rather than
merely detected: the other component keeps its own identity, and there is only
ever one clusterresourcesync-ns-write. Nothing is lost, because in this posture
dataplane.rbac.buckets.clusterresourcesync declares every bucket empty -- the
group it would have formed contributes no rules and emits no object.

It stays in the enumeration in the DEFAULT posture, where its cluster-write
bucket really is emitted through the grouping.
*/}}
{{- if and .Values.clusterresourcesync.enabled
      (not (include "singleNamespace" .))
      (not (include "dataplane.rbac.clusterresourcesyncConstrained" .)) -}}
{{- $components = append $components (dict "name" "clusterresourcesync" "sa" (printf "union-%s" (include "clusterresourcesync.serviceAccountName" .))) -}}
{{- end -}}
{{- toYaml $components -}}
{{- end -}}

{{/*
dataplane.rbac.components collapsed by ServiceAccount, naming the identity each
group renders under. This is a pure function of dataplane.rbac.components plus
the useCommonServiceAccount/common.serviceAccountName inputs -- it enumerates
nothing on its own, so it cannot drift from the set of components
common/rbac.yaml gathers bucket content for: both derive from the same list.

Returns a YAML mapping of serviceAccountName -> identity segment. "Identity" is
the ServiceAccount, NOT the commonServiceAccount flag: flytepropeller,
nodeobserver and clusterresourcesync keep dedicated ServiceAccounts even when
that flag is on, so they are separate identities in every configuration.
*/}}
{{- define "dataplane.rbac.identities" -}}
{{- $components := fromYamlArray (include "dataplane.rbac.components" .) -}}
{{- $shared := include "useCommonServiceAccount" . -}}
{{- $commonSA := include "common.serviceAccountName" . -}}
{{- $out := dict -}}
{{- range $c := $components -}}
{{- $sa := $c.sa -}}
{{- $identity := $c.name -}}
{{- if and $shared (eq $sa $commonSA) -}}
{{- $identity = "union" -}}
{{- end -}}
{{- $_ := set $out $sa $identity -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
dataplane.rbac.components grouped by ServiceAccount, with each group's four
buckets already merged from every enabled component that runs as it.

This is the one place the grouping happens. common/rbac.yaml ranges over this to
emit the role objects, and dataplane.rbac.provisionerBindingTemplates ranges over
it to decide which ns-* roles a runtime provisioner must bind -- so "which roles
exist" and "which roles a provisioner is told to bind" are two readings of one
computation, not two enumerations that could disagree. A RoleBinding naming a
ClusterRole that was never rendered is not a template error and not a runtime
error either: it applies cleanly and grants nothing, which is precisely the
silent-failure class this chart's RBAC helpers exist to make impossible.

A shared ServiceAccount's group is the union of only its ENABLED contributors'
declared buckets -- executor's rules must not leak onto union-system when
executor is disabled and leaseworker is not -- which is why $components (the
per-component {name, sa} pairs) is still needed here alongside $identities (the
collapsed sa -> identity mapping).

Returns a YAML list of groups in first-seen ServiceAccount order, so downstream
emission order is stable across renders. Ranging a dict's keys instead would sort
alphabetically and reorder the rendered manifest.

  - sa: union-system
    identity: union
    ns-read: [...]
    ns-write: [...]
    cluster-read: [...]
    cluster-write: [...]
*/}}
{{- define "dataplane.rbac.groups" -}}
{{- include "dataplane.rbac.groupsExcluding" (dict "ctx" . "exclude" list) -}}
{{- end -}}

{{/*
dataplane.rbac.groups with named components left out of the computation.

Exists to break a template recursion, not as general configurability. The cycle:
dataplane.rbac.bucketRoleNames derives the bind list from these groups ->
computing a group evaluates every component's dataplane.rbac.buckets.* define ->
clusterresourcesync's define embeds the bind rule, whose resourceNames come from
dataplane.rbac.bucketRoleNames. Go templates evaluate a branch only when taken,
so this only bites in the DEFAULT posture, where that bind rule is live; the
constrained posture returns an empty cluster-write bucket and never recurses.
That is why it surfaced as one snapshot rendering empty rather than as a total
failure.

clusterresourcesync is safe to exclude from the bucketRoleNames derivation
specifically: dataplane.rbac.buckets.clusterresourcesync declares `ns-read: []`
and `ns-write: []` in BOTH branches, so it contributes no ns-* bucket names
through this path in any posture. Its one ns-* role, the constrained ns-write,
is emitted directly by clusterresourcesync/serviceaccount.yaml and is added to
the bind list explicitly there -- see bucketRoleNames.

Args: dict with ctx (root) and exclude (list of component names).
*/}}
{{- define "dataplane.rbac.groupsExcluding" -}}
{{- $ctx := .ctx -}}
{{- $exclude := .exclude | default list -}}
{{- $components := fromYamlArray (include "dataplane.rbac.components" $ctx) -}}
{{- $identities := fromYaml (include "dataplane.rbac.identities" $ctx) -}}
{{- $buckets := list "ns-read" "ns-write" "cluster-read" "cluster-write" -}}
{{- $groups := dict -}}
{{- $order := list -}}
{{- range $c := $components -}}
{{- if not (has $c.name $exclude) -}}
{{- if not (hasKey $groups $c.sa) -}}
{{- $group := dict "sa" $c.sa "identity" (index $identities $c.sa) -}}
{{- range $bucket := $buckets -}}
{{- $_ := set $group $bucket list -}}
{{- end -}}
{{- $_ := set $groups $c.sa $group -}}
{{- $order = append $order $c.sa -}}
{{- end -}}
{{- $group := index $groups $c.sa -}}
{{- $decl := fromYaml (include (printf "dataplane.rbac.buckets.%s" $c.name) $ctx) -}}
{{- range $bucket := $buckets -}}
{{- $_ := set $group $bucket (concat (index $group $bucket) (index $decl $bucket | default list)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $sa := $order -}}
{{- $out = append $out (index $groups $sa) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
True when clusterresourcesync is confined to namespaces.managed rather than
holding cluster-scoped RBAC.

Three inputs, all required. namespaces.enabled is one of them, not just
clusterWideBindings and namespaces.managed: this posture routes
clusterresourcesync's rules through dataplane.rbac.emitBucket's
per-namespaces.managed RoleBinding loop, which itself only emits those
RoleBindings when namespaces.enabled is true. Without requiring it here too, a
render with clusterWideBindings: false and a non-empty namespaces.managed but
namespaces.enabled left at its default false would drop clusterresourcesync's
cluster-scoped RBAC while ALSO getting no per-namespace RoleBindings to replace
it with -- a ClusterRole with no binding at all, silently non-functional. Folding
namespaces.enabled in means that combination instead falls back to the default
posture, which is wrong only in the sense of not being maximally confined, not in
the sense of silently bricking the component.

Defined once and included from all three sites that need it
(clusterresourcesync/serviceaccount.yaml twice, clusterresourcesync/configmap.yaml
once). It was previously spelled out inline at two of them with a comment warning
that the copies must be kept in step by hand; a third consumer made that
untenable.

Returns "true" or the empty string, so callers test it with `if`.
*/}}
{{- define "dataplane.rbac.clusterresourcesyncConstrained" -}}
{{- if and (not .Values.rbac.clusterWideBindings) .Values.namespaces.managed .Values.namespaces.enabled -}}true{{- end -}}
{{- end -}}

{{/*
True when a runtime provisioner must create the per-task-namespace RoleBindings,
because cluster-wide bindings are off and the chart is not emitting them itself.

The chart emits a RoleBinding per namespaces.managed entry only when
namespaces.enabled is true AND that list is non-empty -- i.e. exactly when
dataplane.rbac.clusterresourcesyncConstrained is true. Outside that, with
clusterWideBindings false, union workloads hold their ns-* roles only in the
release namespace and have no reach into task namespaces at all until something
binds them there. That something is clusterresourcesync, via the templates
dataplane.rbac.provisionerBindingTemplates generates.

Returns "true" or the empty string.
*/}}
{{- define "dataplane.rbac.provisionerBindingsNeeded" -}}
{{- if and (not .Values.rbac.clusterWideBindings) (not (include "dataplane.rbac.clusterresourcesyncConstrained" .)) -}}true{{- end -}}
{{- end -}}

{{/*
The ns-* bucket ClusterRole names a provisioner needs `bind` on to create
RoleBindings for them in task namespaces.

EXACTLY the ns-* bucket ClusterRoles this render emits -- no more, no less. It is
derived from dataplane.rbac.groups filtered to non-empty buckets, which is the
same computation common/rbac.yaml emits the role objects from, plus the one role
that does not come through groups (see the constrained clusterresourcesync note
below).

Only ns-* appears: cluster-* roles are bound by ClusterRoleBinding, which no
namespaced provisioner should be creating.

An earlier version derived this from dataplane.rbac.identities and deliberately
named roles for identities whose ns-* buckets turned out to be EMPTY, on the
reasoning that a surplus entry is inert because nothing can bind a role that does
not exist. That reasoning holds for roles this chart would author, but the
resourceNames list is not checked against the cluster: a name that no rendered
role answers to may still match a ClusterRole that exists in the live cluster --
a built-in like cluster-admin, or a third-party operator's role that happens to
end in -ns-write. Making the list exact removes the question entirely and lets
the committed RBAC summaries (tests/rbac-summary/) show the bind list and the
rendered roles as one legible block, so a drift between them is a reviewable diff
rather than something buried in an 8,000-line manifest.

Returns a YAML list, for splicing into a resourceNames field.
*/}}
{{- define "dataplane.rbac.bucketRoleNames" -}}
{{- $ctx := . -}}
{{- $names := list -}}
{{/*
clusterresourcesync is excluded from this derivation to break a recursion, and
is safe to exclude because it contributes no ns-* bucket through groups in any
posture -- see dataplane.rbac.groupsExcluding for both halves of that.
*/}}
{{- range $group := fromYamlArray (include "dataplane.rbac.groupsExcluding" (dict "ctx" . "exclude" (list "clusterresourcesync"))) -}}
{{- range $bucket := list "ns-read" "ns-write" -}}
{{- if (index $group $bucket | default list) -}}
{{- $names = append $names (include "dataplane.rbac.roleName" (dict "ctx" $ctx "identity" $group.identity "bucket" $bucket)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{/*
clusterresourcesync's constrained ns-write is the one bucket role that does NOT
come through dataplane.rbac.groups. In that posture
dataplane.rbac.buckets.clusterresourcesync returns every bucket empty and the
role is emitted directly from clusterresourcesync/serviceaccount.yaml instead
(see the comment there), so groups reports both its ns-* buckets as empty while
the ClusterRole is rendered. Without this it would be a rendered role missing
from the bind list, which is a runtime Forbidden in the provisioner with nothing
wrong in the render.
*/}}
{{- if include "dataplane.rbac.clusterresourcesyncConstrained" . -}}
{{- $names = append $names (include "dataplane.rbac.roleName" (dict "ctx" $ctx "identity" "clusterresourcesync" "bucket" "ns-write")) -}}
{{- end -}}
{{- range $name := ($names | uniq | sortAlpha) }}
- {{ $name }}
{{- end }}
{{- end -}}

{{/*
One clusterresource-template entry per RENDERED ns-* bucket role, instructing
clusterresourcesync to create the matching RoleBinding in every task namespace it
provisions.

This is what makes rbac.clusterWideBindings: false workable when the task
namespaces are NOT known ahead of time. The chart cannot enumerate namespaces
that are created at runtime, so it cannot emit those RoleBindings itself; the
`bind` grant in clusterresourcesync's rules authorizes it to create them, but a
grant only permits an attempt. Something has to actually ask for the object, and
in this chart the only thing that runs per-namespace at provision time is
clusterresourcesync's template set. Without these entries the posture renders
clean, applies clean, and leaves every task namespace with no union bindings --
failing at first task execution with a Forbidden that points at RBAC while the
render looks correct.

Derived from dataplane.rbac.groups, and filtered to buckets whose rule list is
non-empty, so the set of RoleBindings requested is exactly the set of ns-* roles
that render. Both directions of that equality matter and neither is checkable at
runtime: a role with no template is a namespace with no grant, and a template
naming a role that does not exist creates a RoleBinding with a dangling roleRef,
which the API server accepts and which grants nothing forever.

dataplane.rbac.bucketRoleNames applies the same non-empty filter, so the bind
list, the rendered roles and these templates are all the same set. That was not
always true: bucketRoleNames used to name roles for empty buckets too, on the
grounds that a surplus resourceNames entry is inert. It is not inert enough --
see that helper's comment.

Keys are prefixed `d_` so they sort after the built-in a_/b_/c_ templates.
Ordering matters to clusterresourcesync: it reads the template directory with
ioutil.ReadDir, which returns entries sorted by filename, and applies them in
that order -- so a_namespace must still create the namespace before anything is
placed in it.

The `{{ namespace }}` in the emitted manifest is clusterresourcesync's own
placeholder, substituted per project/domain at provision time. It is passed
through as a literal here (the template ConfigMap does not tpl these values) --
hence the raw-string quoting.

Returns a YAML list of {key, value} entries, matching the shape of
clusterresourcesync.templates.
*/}}
{{- define "dataplane.rbac.provisionerBindingTemplates" -}}
{{- $ctx := . -}}
{{- $out := list -}}
{{/*
The webhook's ServiceAccount, so its bindings can be ordered FIRST. See the
phase-prefix comment below.
*/}}
{{- $webhookSA := "" -}}
{{- if .Values.flytepropellerwebhook.enabled -}}
{{- $webhookSA = include "webhook.serviceAccountName" . -}}
{{- end -}}
{{- range $group := fromYamlArray (include "dataplane.rbac.groups" .) -}}
{{- range $bucket := list "ns-read" "ns-write" -}}
{{- if (index $group $bucket | default list) -}}
{{- $name := include "dataplane.rbac.roleName" (dict "ctx" $ctx "identity" $group.identity "bucket" $bucket) -}}
{{- $manifest := include "dataplane.rbac.provisionerBindingManifest" (dict "name" $name "sa" $group.sa "ctx" $ctx) -}}
{{/*
Phase prefix, and it is load-bearing rather than cosmetic.

clusterresourcesync applies this directory in FILENAME ORDER, one file at a
time, continuing past failures. Ordering by identity alone put the webhook last
(executor, flytepropeller, leaseworker, operator, proxy, webhook), which meant
executor and operator -- both able to create task pods -- received their reach in
a freshly provisioned namespace BEFORE the webhook received `secrets` write
there. A pod created in that window is admitted without its image-pull secret and
fails with ImagePullBackOff, and the webhook's Forbidden is swallowed rather than
surfaced. That is precisely the failure the webhook's own guard exists to
prevent, reintroduced through the back door by a sort order.

00 is the webhook's own ServiceAccount; 10 is everything else. Within a phase the
identity ordering is unchanged. Only split identities are affected: under the
shared ServiceAccount the webhook IS union-system, so its binding and the
pod-creators' binding are the same object and no window exists.

An operator-supplied external provisioner has to honour the same ordering; the
chart cannot enforce that, and rbac.externalBindingProvisioner's documentation
says so.
*/}}
{{- $phase := "10" -}}
{{- if and $webhookSA (eq $group.sa $webhookSA) -}}
{{- $phase = "00" -}}
{{- end -}}
{{- $out = append $out (dict "key" (printf "d_union_rolebinding_%s_%s_%s" $phase $group.identity $bucket) "value" $manifest) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
The RoleBinding manifest body for one ns-* role, as a clusterresourcesync
template. Split out from dataplane.rbac.provisionerBindingTemplates so the YAML
is written as YAML rather than assembled by printf.

roleRef is always kind: ClusterRole. These entries only render at
low_privilege: false (clusterresourcesync does not render at all in
single-namespace mode), which is the mode in which dataplane.rbac.emitBucket
emits ns-* buckets as ClusterRoles. A RoleBinding referencing a ClusterRole
scopes that ClusterRole's rules to the RoleBinding's own namespace, which is the
entire mechanism this posture rests on.

Args: dict with name (the ns-* role, used for both the binding and the roleRef),
sa (the ServiceAccount to bind), ctx (root, for the release namespace).
*/}}
{{- define "dataplane.rbac.provisionerBindingManifest" -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .name }}
  namespace: {{ `{{ namespace }}` }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ .name }}
subjects:
  - kind: ServiceAccount
    name: {{ .sa }}
    namespace: {{ .ctx.Release.Namespace }}
{{- end -}}
