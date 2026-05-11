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
Tenant hostname and organization required whenever the gateway is enabled.
The bootstrap configmap interpolates host for the listener domain and CORS
allow_origin (rendered regardless of gateway.auth.enable), and the Envoy
auth env-var fallbacks use both; emitting empty values silently produces
broken URLs like `https://` or `<cluster>.dp.`.
*/}}
{{- define "gateway.host" -}}
{{- required "host is required when gateway.enable is true" (tpl .Values.host .) -}}
{{- end }}

{{- define "gateway.organization" -}}
{{- required "orgName is required when gateway.enable is true" (tpl .Values.orgName .) -}}
{{- end }}

{{/*
Collector: aggregates all backend envoy routes.
To add a new backend, add a conditional include block here.
NOTE: dataproxy.envoyRoute is a catch-all (prefix "/") and must remain last.
Place more specific routes above it or they will be shadowed.
*/}}
{{- define "gateway.extraRoutes" -}}
{{- if .Values.union.dataproxy.enable }}
{{- include "dataproxy.envoyRoute" . }}
{{- end }}
{{- end -}}

{{/*
Collector: aggregates all backend envoy clusters.
To add a new backend, add a conditional include block here.
*/}}
{{- define "gateway.extraClusters" -}}
{{- if .Values.union.dataproxy.enable }}
{{- include "dataproxy.envoyCluster" . }}
{{- end }}
{{- end -}}
