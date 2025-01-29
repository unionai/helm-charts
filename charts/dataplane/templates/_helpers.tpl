{{/*
Expand the name of the chart.
*/}}
{{- define "union-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "union-operator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Output the cluster name
*/}}
{{- define "getClusterName" -}}
{{- (tpl .Values.clusterName .) -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "union-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "flytepropeller.selectorLabels" -}}
app.kubernetes.io/name: flytepropeller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flytepropeller.labels" -}}
{{ include "flytepropeller.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flytepropeller.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "flytepropeller.labels" . }}
{{- with .Values.flytepropeller.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "flytepropellerwebhook.selectorLabels" -}}
app.kubernetes.io/name: flytepropellerwebhook
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flytepropellerwebhook.labels" -}}
{{ include "flytepropellerwebhook.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flytepropellerwebhook.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "flytepropellerwebhook.labels" . }}
{{- with .Values.flytepropellerwebhook.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "clusterresourcesync.selectorLabels" -}}
app.kubernetes.io/name: clusterresourcesync
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "clusterresourcesync.labels" -}}
{{ include "clusterresourcesync.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "clusterresourcesync.podLabels" -}}
{{ include "clusterresourcesync.labels" . }}
{{- with .Values.clusterresourcesync.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "operator.serviceAccountName" -}}
{{- default "operator-system" .Values.operator.serviceAccount.name }}
{{- end }}

{{- define "operator.selectorLabels" -}}
app.kubernetes.io/name: operator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "operator.labels" -}}
{{ include "operator.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "operator.podLabels" -}}
{{ include "operator.labels" . }}
{{- with .Values.operator.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "proxy.serviceAccountName" -}}
{{- default "proxy-system" .Values.proxy.serviceAccount.name }}
{{- end }}

{{- define "proxy.selectorLabels" -}}
app.kubernetes.io/name: operator-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "proxy.labels" -}}
{{ include "proxy.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "proxy.podLabels" -}}
{{ include "proxy.labels" . }}
{{- with .Values.operator.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "kubeStateMetrics.serviceAccountName" -}}
{{- default "kube-state-metrics" .Values.kubeStateMetrics.serviceAccount.name }}
{{- end }}

{{- define "kubeStateMetrics.selectorLabels" -}}
app.kubernetes.io/name: kube-state-metrics
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "kubeStateMetrics.labels" -}}
{{ include "kubeStateMetrics.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "kubeStateMetrics.podLabels" -}}
{{ include "proxy.labels" . }}
{{- with .Values.operator.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}


{{/*
Create the name of the service account to use
*/}}
{{- define "dcgmExporter.serviceAccountName" -}}
{{- default "dcgm-exporter-system" .Values.dcgmExporter.serviceAccount.name }}
{{- end }}

{{- define "dcgmExporter.selectorLabels" -}}
app.kubernetes.io/name: dcgm-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "dcgmExporter.labels" -}}
{{ include "dcgmExporter.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "dcgmExporter.podLabels" -}}
{{ include "proxy.labels" . }}
{{- with .Values.operator.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}


{{- define "var.FLYTE_AWS_ENDPOINT" -}}
{{- with .Values.storage.endpoint }}
- FLYTE_AWS_ENDPOINT: {{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "var.FLYTE_AWS_ACCESS_KEY_ID" -}}
{{- with .Values.storage.accessKey }}
- FLYTE_AWS_ACCESS_KEY_ID: {{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "var.FLYTE_AWS_SECRET_ACCESS_KEY" -}}
{{- with .Values.storage.secretKey }}
- FLYTE_AWS_SECRET_ACCESS_KEY: {{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "k8s.default-env-vars" -}}
plugins:
  k8s:
    default-env-vars:
      {{ include "var.FLYTE_AWS_ENDPOINT" . | indent 6 }}
      {{ include "var.FLYTE_AWS_ACCESS_KEY_ID" . | indent 6 }}
      {{ include "var.FLYTE_AWS_SECRET_ACCESS_KEY" . | indent 6 }}
{{- end -}}

{{- define "additionalPodEnvVars" -}}
plugins:
  k8s:
    default-env-vars:
      {{ .Values.additionalPodEnvVars | toYaml | indent 6 }}
{{- end -}}

{{/*
Set the default environment variables for the k8s plugin.  If access
key authentication is used, the appropriate environment variables to
access the storage is injected.
*/}}
{{- define "k8s.plugins" -}}
{{- $extra := include "additionalPodEnvVars" . | fromYaml }}
{{- $plugins := merge .Values.config.k8s $extra }}
{{- if and (.Values.storage.injectPodEnvVars) (eq .Values.storage.authType "accesskey") }}
{{- $injected := include "k8s.default-env-vars" . | fromYaml }}
{{- $plugins := merge .Values.config.k8s $injected }}
{{- end }}
{{- with $plugins }}
{{- (toYaml .) }}
{{- end }}
{{- end -}}

{{/*
Health check URL helpers
*/}}
{{- define "prometheus.health.url" -}}
http://{{ template "kube-prometheus-stack.fullname" . }}-prometheus.{{ .Release.Namespace }}.svc.cluster.local:9090/-/healthy
{{- end -}}

{{- define "propeller.health.url" -}}
http://flytepropeller.{{ .Release.Namespace }}.svc.cluster.local:10254
{{- end -}}

{{- define "proxy.health.url" -}}
http://union-operator-proxy.{{ .Release.Namespace }}.svc.cluster.local:10254
{{- end -}}

{{/*
Global pod annotations
*/}}
{{- define "global.podAnnotations" -}}
{{- if .Values.monitoring.prometheus }}
prometheus.io/scrape: "true"
{{- end }}
prometheus.io/path: "/metrics"
prometheus.io/port: "10254"
{{- with .Values.additionalPodAnnotations }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
Global pod labels
*/}}
{{- define "global.podLabels" -}}
{{- with .Values.additionalPodLabels }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
Global pod environment variables
*/}}
{{- define "global.podEnvVars" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: GOMEMLIMIT
  valueFrom:
    resourceFieldRef:
      resource: limits.memory
- name: GOMAXPROCS
  valueFrom:
    resourceFieldRef:
      resource: limits.cpu
{{- with .Values.additionalPodEnvVars }}
{{- toYaml .}}
{{- end }}
{{- end -}}