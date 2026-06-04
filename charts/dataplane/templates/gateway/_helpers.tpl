{{/*
Fully qualified gateway resource name.
Follows the parent chart convention: {union-operator.fullname}-gateway.
*/}}
{{- define "gateway.fullname" -}}
{{- printf "%s-gateway" (include "union-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Helm-standard labels applied to all gateway resources.
*/}}
{{- define "gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Upstream Knative identity labels.
Applied to all knative-serving resources.
*/}}
{{- define "gateway.knativeLabels" -}}
app.kubernetes.io/name: knative-serving
app.kubernetes.io/version: "1.16.0"
{{- end }}

{{/*
Tenant hostname and organization helpers used in the gateway path.

host is consumed unconditionally by the bootstrap configmap (listener
domain and CORS allow_origin), so it is required whenever zero_trust is
enabled.

organization is consumed only by the Envoy auth fallback path
(gateway.auth.enable=true with no gateway.auth.organization override),
so it is required only in that configuration. Emitting empty values for
either silently produces broken URLs like `https://` or `<cluster>.dp.`.
*/}}
{{- define "gateway.host" -}}
{{- required "host is required when zero_trust.enabled is true" (tpl .Values.host .) -}}
{{- end }}

{{- define "gateway.organization" -}}
{{- required "orgName is required when gateway.auth.enable is true and gateway.auth.organization is unset" (tpl .Values.orgName .) -}}
{{- end }}

{{/*
Collector: aggregates all backend envoy routes.
To add a new backend, add a conditional include block here.
NOTE: dataproxy.envoyRoute is a catch-all (prefix "/") and must remain last.
Place more specific routes above it or they will be shadowed.
*/}}
{{- define "gateway.extraRoutes" -}}
{{- if .Values.zero_trust.enabled }}
{{- include "dataproxy.envoyRoute" . }}
{{- end }}
{{- end -}}

{{/*
Collector: aggregates all backend envoy clusters.
To add a new backend, add a conditional include block here.
*/}}
{{- define "gateway.extraClusters" -}}
{{- if .Values.zero_trust.enabled }}
{{- include "dataproxy.envoyCluster" . }}
{{- end }}
{{- end -}}
