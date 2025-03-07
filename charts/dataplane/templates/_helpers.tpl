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

{{/*
Adds custom PodSpec values.
*/}}
{{- define "additionalPodSpec" -}}
{{- with .Values.additionalPodSpec }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "flytepropeller.selectorLabels" -}}
app.kubernetes.io/name: flytepropeller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flytepropeller.labels" -}}
{{ include "flytepropeller.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flytepropeller.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "flytepropeller.labels" . }}
{{- with .Values.flytepropeller.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "flytepropeller.scheduling.topologySpreadConstraints" -}}
{{ with .Values.flytepropeller.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropeller.scheduling.affinity" -}}
{{ with .Values.flytepropeller.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropeller.scheduling.nodeSelector" -}}
{{ with .Values.flytepropeller.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropeller.scheduling.nodeName" -}}
{{ with .Values.flytepropeller.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "flytepropeller.scheduling.tolerations" -}}
{{ with .Values.flytepropeller.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropeller.scheduling" -}}
{{- if .Values.flytepropeller.topologySpreadConstraints }}
{{- include "flytepropeller.scheduling.topologySpreadConstraints" . }}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.flytepropeller.affinity }}
{{- include "flytepropeller.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.flytepropeller.nodeSelector }}
{{- include "flytepropeller.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.flytepropeller.nodeName }}
{{- include "flytepropeller.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.flytepropeller.tolerations }}
{{- include "flytepropeller.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
{{- end }}
{{- end -}}

{{- define "flytepropellerwebhook.selectorLabels" -}}
app.kubernetes.io/name: flytepropellerwebhook
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flytepropellerwebhook.labels" -}}
{{ include "flytepropellerwebhook.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flytepropellerwebhook.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "flytepropellerwebhook.labels" . }}
{{- with .Values.flytepropellerwebhook.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "flytepropellerwebhook.scheduling.topologySpreadConstraints" -}}
{{ with .Values.flytepropellerwebhook.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropellerwebhook.scheduling.affinity" -}}
{{ with .Values.flytepropellerwebhook.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropellerwebhook.scheduling.nodeSelector" -}}
{{ with .Values.flytepropellerwebhook.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropellerwebhook.scheduling.nodeName" -}}
{{ with .Values.flytepropellerwebhook.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "flytepropellerwebhook.scheduling.tolerations" -}}
{{ with .Values.flytepropellerwebhook.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "flytepropellerwebhook.scheduling" -}}
{{- if .Values.flytepropellerwebhook.topologySpreadConstraints }}
{{- include "flytepropellerwebhook.scheduling.topologySpreadConstraints"}}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.flytepropellerwebhook.affinity }}
{{- include "flytepropellerwebhook.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.flytepropellerwebhook.nodeSelector }}
{{- include "flytepropellerwebhook.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.flytepropellerwebhook.nodeName }}
{{- include "flytepropellerwebhook.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.flytepropellerwebhook.tolerations }}
{{- include "flytepropellerwebhook.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
{{- end }}
{{- end -}}

{{/*
Create the name of the clusterresources service account
*/}}
{{- define "clusterresourcesync.serviceAccountName" -}}
{{- default "clustersync-system" .Values.clusterresourcesync.serviceAccount.name }}
{{- end }}

{{- define "clusterresourcesync.selectorLabels" -}}
app.kubernetes.io/name: clusterresourcesync
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "clusterresourcesync.labels" -}}
{{ include "clusterresourcesync.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "clusterresourcesync.podLabels" -}}
{{ include "clusterresourcesync.labels" . }}
{{- with .Values.clusterresourcesync.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "clusterresourcesync.scheduling.topologySpreadConstraints" -}}
{{ with .Values.clusterresourcesync.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "clusterresourcesync.scheduling.affinity" -}}
{{ with .Values.clusterresourcesync.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "clusterresourcesync.scheduling.nodeSelector" -}}
{{ with .Values.clusterresourcesync.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "clusterresourcesync.scheduling.nodeName" -}}
{{ with .Values.clusterresourcesync.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "clusterresourcesync.scheduling.tolerations" -}}
{{ with .Values.clusterresourcesync.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "clusterresourcesync.scheduling" -}}
{{- if .Values.clusterresourcesync.topologySpreadConstraints }}
{{- include "clusterresourcesync.scheduling.topologySpreadConstraints" . }}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.clusterresourcesync.affinity }}
{{- include "clusterresourcesync.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.clusterresourcesync.nodeSelector }}
{{- include "clusterresourcesync.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.clusterresourcesync.nodeName }}
{{- include "clusterresourcesync.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.clusterresourcesync.tolerations }}
{{- include "clusterresourcesync.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
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
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "operator.podLabels" -}}
{{ include "operator.labels" . }}
{{- with .Values.operator.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "operator.scheduling.topologySpreadConstraints" -}}
{{ with .Values.operator.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "operator.scheduling.affinity" -}}
{{ with .Values.operator.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "operator.scheduling.nodeSelector" -}}
{{ with .Values.operator.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "operator.scheduling.nodeName" -}}
{{ with .Values.operator.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "operator.scheduling.tolerations" -}}
{{ with .Values.operator.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "operator.scheduling" -}}
{{- if .Values.operator.topologySpreadConstraints }}
{{- include "operator.scheduling.topologySpreadConstraints" . }}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.operator.affinity }}
{{- include "operator.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.operator.nodeSelector }}
{{- include "operator.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.operator.nodeName }}
{{- include "operator.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.operator.tolerations }}
{{- include "operator.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
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
platform.union.ai/service-group: {{ .Release.Name }}
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
{{ include "kubeStateMetrics.labels" . }}
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
{{ include "dcgmExporter.labels" . }}
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

{{- define "k8s.plugins.defaultEnvVariables" -}}
plugins:
  k8s:
    default-env-vars:
      {{- if and ($.Values.storage.injectPodEnvVars) (eq $.Values.storage.authType "accesskey") }}
      {{ include "var.FLYTE_AWS_ENDPOINT" . | indent 6 }}
      {{ include "var.FLYTE_AWS_ACCESS_KEY_ID" . | indent 6 }}
      {{ include "var.FLYTE_AWS_SECRET_ACCESS_KEY" . | indent 6 }}
      {{- end }}
      {{- range $k, $v := .Values.additionalPodEnvVars }}
      - {{ $k }}: {{ $v }}
      {{- end }}
      {{- $configDevEnvVars := index .Values.config.k8s.plugins.k8s "default-env-vars" }}
      {{- range $kk, $vv := $configDevEnvVars }}
      {{- range $k, $v := $vv }}
      - {{ $k }}: {{ $v }}
      {{- end }}
      {{- end }}
{{- end -}}

{{/*
Set the default environment variables for the k8s plugin.  If access
key authentication is used, the appropriate environment variables to
access the storage is injected.
*/}}
{{- define "k8s.plugins" -}}
{{- $plugins := include "k8s.plugins.defaultEnvVariables" . | fromYaml }}
{{- $_ := merge $plugins .Values.config.k8s }}
{{- with $plugins }}
{{- (toYaml .) }}
{{- end }}
{{- end -}}

{{- define "prometheus.health.url" -}}
http://union-prometheus.{{ .Release.Namespace }}.svc.cluster.local:9090/-/healthy
{{- end -}}

{{- define "prometheus.service.url" -}}
http://union-prometheus.{{ .Release.Namespace }}.svc.cluster.local:9090
{{- end -}}

{{- define "propeller.health.url" -}}
http://flytepropeller.{{ .Release.Namespace }}.svc.cluster.local:10254
{{- end -}}

{{- define "proxy.health.url" -}}
http://operator-proxy.{{ .Release.Namespace }}.svc.cluster.local:10254
{{- end -}}

{{- define "proxy.service.url" -}}
http://operator-proxy.{{ .Release.Namespace }}.svc.cluster.local:8080
{{- end -}}

{{- define "proxy.scheduling.topologySpreadConstraints" -}}
{{ with .Values.proxy.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "proxy.scheduling.affinity" -}}
{{ with .Values.proxy.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "proxy.scheduling.nodeSelector" -}}
{{ with .Values.proxy.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "proxy.scheduling.nodeName" -}}
{{ with .Values.proxy.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "proxy.scheduling.tolerations" -}}
{{ with .Values.proxy.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "proxy.scheduling" -}}
{{- if .Values.proxy.topologySpreadConstraints }}
{{- include "proxy.scheduling.topologySpreadConstraints" . }}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.proxy.affinity }}
{{- include "proxy.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.proxy.nodeSelector }}
{{- include "proxy.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.proxy.nodeName }}
{{- include "proxy.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.proxy.tolerations }}
{{- include "proxy.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
{{- end }}
{{- end -}}

{{- define "knative.proxy.service.url" -}}
http://kourier-internal.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/*
Global pod annotations
*/}}
{{- define "global.podAnnotations" -}}
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
Additional pod environment variables
*/}}
{{- define "global.podEnvVars.additionalPodEnvVars" -}}
{{- range $k, $v := .Values.additionalPodEnvVars }}
- name: {{ $k }}
  value: {{ $v }}
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
- name: CLUSTER_NAME
  valueFrom:
    secretKeyRef:
      name: operator-cluster-name
      key: cluster_name
- name: DEPLOYMENT_NAME
  value: operator
- name: PROXY_SERVICE_URL
  value: {{ include "proxy.service.url" . }}
- name: PROMETHEUS_SERVICE_URL
  value: {{ include "prometheus.service.url" . }}
- name: KNATIVE_PROXY_SERVICE_URL
  value: {{ include "knative.proxy.service.url" . }}
{{- include "global.podEnvVars.additionalPodEnvVars" . }}
{{- end -}}

{{- define "global.scheduling.topologySpreadConstraints" -}}
{{- with .Values.scheduling.topologySpreadConstraints }}
topologySpreadConstraints
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "global.scheduling.affinity" -}}
{{- with .Values.scheduling.affinity }}
affinity:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "global.scheduling.nodeSelector" -}}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "global.scheduling.tolerations" -}}
{{- with .Values.scheduling.tolerations }}
tolerations:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "global.scheduling.nodeName" -}}
{{- with .Values.scheduling.nodeName }}
nodeName: {{- toYaml . }}
{{- end }}
{{- end -}}