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
{{- if and .Values.clusterresourcesync.enabled (not (include "singleNamespace" .)) -}}
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
The ns-* bucket ClusterRole names a provisioner may need to bind into task
namespaces, derived from dataplane.rbac.identities so the list can never be
narrower than what the emitter renders.

Only ns-* appears: cluster-* roles are bound by ClusterRoleBinding, which no
namespaced provisioner should be creating.

Names are emitted even for identities whose ns-* buckets turn out to be empty,
so no role is ever rendered without a matching bind entry. A resourceNames entry
for a role that does not exist is an inert no-op; the reverse -- a rendered role
missing from the list -- is a runtime Forbidden. The check in this task's Step 4
enforces that direction specifically.

Returns a YAML list, for splicing into a resourceNames field.
*/}}
{{- define "dataplane.rbac.bucketRoleNames" -}}
{{- $ctx := . -}}
{{- $identities := fromYaml (include "dataplane.rbac.identities" .) -}}
{{- $names := list -}}
{{- range $sa, $identity := $identities -}}
{{- range $bucket := list "ns-read" "ns-write" -}}
{{- $names = append $names (include "dataplane.rbac.roleName" (dict "ctx" $ctx "identity" $identity "bucket" $bucket)) -}}
{{- end -}}
{{- end -}}
{{- range $name := ($names | uniq | sortAlpha) }}
- {{ $name }}
{{- end }}
{{- end -}}
