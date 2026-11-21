{{/*
Knative Serving, vendored from the dataplane chart's zero-trust gateway
(charts/dataplane/templates/gateway, Knative Serving 1.23): the controller,
activator, autoscaler and webhook, their config-* ConfigMaps and RBAC, run in
the release namespace. The CRDs are in this chart's crds/ (synced from the
dataplane's by crds/onebox/scripts/sync.sh). Union's Kourier controller and
Envoy gateway are templates/kourier.yaml.
*/}}

{{/* onebox.knative.install: "true" when this chart runs Knative Serving
itself, "" otherwise (callers gate with `if include ...`). */}}
{{- define "onebox.knative.install" -}}
{{- if and .Values.serving.enabled .Values.serving.knative.install -}}true{{- end -}}
{{- end }}

{{/* onebox.knative.namespace: where Knative Serving's control plane and its
config-* ConfigMaps (config-network, config-kourier, ...) live. */}}
{{- define "onebox.knative.namespace" -}}
{{- if include "onebox.knative.install" . -}}
{{- .Release.Namespace -}}
{{- else -}}
{{- .Values.serving.knativeNamespace -}}
{{- end -}}
{{- end }}

{{/* Helm labels on every Knative resource. Not onebox.labels: its
app.kubernetes.io/name would clash with Knative's own. */}}
{{- define "onebox.knative.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Upstream Knative identity labels. The config webhook selects its
ConfigMaps by these. */}}
{{- define "onebox.knative.knativeLabels" -}}
app.kubernetes.io/name: knative-serving
app.kubernetes.io/version: "1.23.0"
{{- end }}

{{/* Registries Knative leaves image tags unresolved for: plain-HTTP or
authenticated registries it could not read a digest from. Includes the image
builder's registry (the host of imageBuilder.repository) when it is on, so
apps built by onebox deploy without extra config. */}}
{{- define "onebox.knative.skipTagRegistries" -}}
{{- include "onebox.bundled" . -}}
{{- $regs := list "kind.local" "ko.local" "dev.local" -}}
{{- if and .Values.imageBuilder.enabled .Values.imageBuilder.repository -}}
{{- $regs = prepend $regs (first (splitList "/" .Values.imageBuilder.repository)) -}}
{{- end -}}
{{- join "," (uniq $regs) -}}
{{- end }}
