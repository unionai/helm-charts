{{/*
Support our existing naming schema.
*/}}
{{- define "union-operator.name" -}}
union-operator
{{- end }}

{{- define "union-operator.fullname" -}}
union-operator
{{- end }}

{{/*
In the future we will most likely add in a true operator to manage
deployments.  At that time the existing "operator" service will be
migrated to the "dataplane" service and will use these.
*/}}
{{- define "unionai-dataplane.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "unionai-dataplane.fullname" -}}
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

{{- define "nodeobserver.serviceAccountName" -}}
{{- default "nodeobserver-system" .Values.nodeobserver.serviceAccount.name }}
{{- end }}

{{- define "nodeobserver.selectorLabels" -}}
app.kubernetes.io/name: nodeobserver
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "nodeobserver.labels" -}}
{{ include "nodeobserver.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "nodeobserver.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "nodeobserver.labels" . }}
{{- with .Values.nodeobserver.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "nodeobserver.scheduling.topologySpreadConstraints" -}}
{{ with .Values.nodeobserver.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "nodeobserver.scheduling.affinity" -}}
{{ with .Values.nodeobserver.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "nodeobserver.scheduling.nodeSelector" -}}
{{ with .Values.nodeobserver.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "nodeobserver.scheduling.nodeName" -}}
{{ with .Values.nodeobserver.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "nodeobserver.scheduling.tolerations" -}}
{{ with .Values.nodeobserver.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "nodeobserver.scheduling" -}}
{{- if .Values.nodeobserver.topologySpreadConstraints }}
{{- include "nodeobserver.scheduling.topologySpreadConstraints"}}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.nodeobserver.affinity }}
{{- include "nodeobserver.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.nodeobserver.nodeSelector }}
{{- include "nodeobserver.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.nodeobserver.nodeName }}
{{- include "nodeobserver.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.nodeobserver.tolerations }}
{{- include "nodeobserver.scheduling.tolerations" . }}
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
app.kubernetes.io/name: union-operator
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

{{- define "operator.clusterData" -}}
clusterData:
  {{- with .Values.config.operator.clusterData }}
  {{- tpl (toYaml .) $ | nindent 2 }}
  {{- end }}
  {{- with .Values.storage.custom }}
  # -- storageType is only used when syncClusterConfig is enabled. It is intentionally disabled and it should not be used.
  storageType: custom
  customStorageConfig: |
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "proxy.serviceAccountName" -}}
{{- default "proxy-system" .Values.proxy.serviceAccount.name }}
{{- end }}

{{- define "proxy.secretsNamespace" -}}
{{- default .Release.Namespace .Values.proxy.secretManager.namespace }}
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
http://{{ include "union-operator.fullname" . }}-prometheus:80/-/healthy
{{- end -}}

{{- define "prometheus.service.url" -}}
http://{{ include "union-operator.fullname" . }}-prometheus:80
{{- end -}}

{{- define "propeller.health.url" -}}
http://flytepropeller:10254
{{- end -}}

{{- define "proxy.health.url" -}}
http://{{ include "union-operator.fullname" . }}-proxy:10254
{{- end -}}

{{- define "proxy.service.url" -}}
http://{{ include "union-operator.fullname" . }}-proxy:8080
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
http://kourier-internal
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
      divisor: 1
      resource: limits.memory
- name: GOMAXPROCS
  valueFrom:
    resourceFieldRef:
      divisor: 1
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

{{/*
Global service account annotations
*/}}
{{- define "global.serviceAccountAnnotations" -}}
{{- with .Values.additionalServiceAccountAnnotations }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
Name of the fluentbit configMap
*/}}
{{- define "fluentbit.configMapName" -}}
{{- .Values.fluentbit.existingConfigMap }}
{{- end }}

{{- define "fluentbit.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fluentbit.customParsers" -}}
[PARSER]
    Name docker_no_time
    Format json
    Time_Keep Off
    Time_Key time
    Time_Format %Y-%m-%dT%H:%M:%S.%L
{{- end }}

{{- define "fluentbit.service" -}}
[SERVICE]
    Parsers_File /fluent-bit/etc/parsers.conf
    Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
    HTTP_Server On
    HTTP_Listen 0.0.0.0
    Health_Check On
{{- end }}

{{- define "fluentbit.inputs" -}}
[INPUT]
    Name                tail
    Tag                 namespace-<namespace_name>.pod-<pod_name>.cont-<container_name>
    Tag_Regex           (?<pod_name>[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace_name>[^_]+)_(?<container_name>.+)-
    Path                /var/log/containers/*.log
    DB                  /var/log/flb_kube.db
    multiline.parser    docker, cri
    Mem_Buf_Limit       5MB
    Skip_Long_Lines     On
    Refresh_Interval    10
{{- end }}

{{- define "fluentbit.filters" -}}
{{- end }}

{{- define "fluentbit.outputs" -}}
{{- if eq .Values.config.proxy.persistedLogs.sourceType "ObjectStore" }}
{{/* azure uses a different output plugin*/}}
{{- if and (hasKey .Values.storage "custom") (hasKey .Values.storage.custom "stow") (eq .Values.storage.custom.stow.kind "azure") }}
[OUTPUT]
    name                  azure_blob
    match                 *
{{- with .Values.storage.custom.stow.config.account }}
    account_name {{ . }}
{{- end }}
    auth_type             key
{{- with .Values.storage.custom.stow.config.key }}
    shared_key {{ . }}
{{- end }}
    path                  {{ .Values.config.proxy.persistedLogs.objectStore.prefix }}
    container_name        {{ .Values.storage.custom.container }}
    tls                   on
{{- else }}
[OUTPUT]
    Name s3
    Match *
    upload_timeout 1m
    s3_key_format /{{ .Values.config.proxy.persistedLogs.objectStore.prefix }}/$TAG
    static_file_path true
    json_date_key false
{{- with .Values.storage.region }}
    region {{ . }}
{{- end }}
{{- with .Values.storage.bucketName }}
    bucket {{ . }}
{{- end }}
{{- with .Values.storage.endpoint }}
    endpoint {{ . }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create a full name prefix for serving resources
*/}}
{{- define "serving.fullname" -}}
{{- $name := include "union-operator.fullname" . }}
{{- printf "%s-serving" $name }}
{{- end }}

{{/*
Name of the serving-envoy-bootstrap ConfigMap
*/}}
{{- define "serving.envoyBootstrapConfigMapName" -}}
{{- include "serving.fullname" . }}-envoy-bootstrap
{{- end }}

# Image Builder helpers

{{/*
The name of the buildkit deployment, service, etc
*/}}
{{- define "imagebuilder.buildkit.fullname" -}}
{{- if .Values.imageBuilder.buildkit.fullnameOverride }}
{{- .Values.imageBuilder.buildkit.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" (include "union-operator.fullname" .) "buildkit" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "imagebuilder.buildkit.selectorLabels" -}}
app.kubernetes.io/name: imagebuilder-buildkit
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "imagebuilder.buildkit.labels" -}}
{{ include "imagebuilder.buildkit.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Check if both imageBuilder and imageBuilder.buildkit are enabled
*/}}
{{- define "imagebuilder.buildkit.enabled" -}}
{{- if and .Values.imageBuilder.enabled .Values.imageBuilder.buildkit.enabled }}
{{- true }}
{{- else }}
{{- end }}
{{- end }}

{{/*
The URI to connect to buildkit
*/}}
{{- define "imagebuilder.buildkit.uri" -}}
{{- if .Values.imageBuilder.buildkitUri -}}
{{- .Values.imageBuilder.buildkitUri | quote -}}
{{- else -}}
tcp://{{ include "imagebuilder.buildkit.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.imageBuilder.buildkit.service.port }}
{{- end -}}
{{- end -}}

{{- define "ingress.serving.host" -}}
{{- if .Values.ingress.serving.hostOverride }}
{{- .Values.ingress.serving.hostOverride | quote }}
{{- else }}
{{- printf "*.apps.%s" .Values.host | quote }}
{{- end }}
{{- end -}}
