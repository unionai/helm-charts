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
*/}}
{{- define "dataplane.rbac.emitBucket" -}}
{{- $rules := .rules | default list -}}
{{- if $rules -}}
{{- $isCluster := include "dataplane.rbac.isClusterBucket" .bucket -}}
{{- $name := include "dataplane.rbac.roleName" (dict "ctx" .ctx "identity" .identity "bucket" .bucket) -}}
{{- if and $isCluster .ctx.Values.low_privilege -}}
{{- fail (printf "RBAC bucket %q for %q is non-empty under low_privilege: true. Cluster-scoped grants cannot be conveyed by any namespaced Role, so the COMPONENT must be gated rather than its rules degraded. See the gating framework in docs/superpowers/specs/2026-08-04-dataplane-rbac-scope-split-design.md section 6." .bucket .identity) -}}
{{- end -}}
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
{{- $nsRoleKind := include "dataplane.rbacKind" .ctx -}}
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
{{- end -}}
{{- end -}}
