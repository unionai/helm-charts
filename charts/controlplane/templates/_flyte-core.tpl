{{- define "flyte.namespace" -}}
{{- default .Release.Namespace .Values.forceNamespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "flyteadmin.name" -}}
flyteadmin
{{- end -}}

{{- define "flyteadmin.selectorLabels" -}}
app.kubernetes.io/name: {{ template "flyteadmin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "flyte.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}


{{- define "flyteadmin.labels" -}}
{{ include "flyteadmin.selectorLabels" . }}
helm.sh/chart: {{ include "flyte.chart" . }}
#app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
