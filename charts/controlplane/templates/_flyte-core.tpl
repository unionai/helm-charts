{{/*
Flyte component helpers.

These were originally defined in the flyte-core subchart _helpers.tpl and overridden
here. As part of FAB-277 (remove flyte-core subchart), they are now the canonical
definitions. Direct templates in templates/flyteadmin/ and templates/flyteconsole/
use these helpers.

NOTE: Labels intentionally differ from the old subchart output:
  - helm.sh/chart uses the controlplane chart version (was flyte-core-v1.16.1)
  - app.kubernetes.io/managed-by is included (was commented out)
  This requires `helm upgrade --force` when upgrading from subchart-based releases.
*/}}

{{- define "flyte.namespace" -}}
{{- default .Release.Namespace .Values.forceNamespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Chart label — uses controlplane chart identity (breaking change from subchart) */}}
{{- define "flyte.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "flyte.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ---- flyteadmin ---- */}}

{{- define "flyteadmin.name" -}}
flyteadmin
{{- end -}}

{{- define "flyteadmin.selectorLabels" -}}
app.kubernetes.io/name: {{ template "flyteadmin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flyteadmin.labels" -}}
{{ include "flyteadmin.selectorLabels" . }}
helm.sh/chart: {{ include "flyte.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flyteadmin.podLabels" -}}
{{ include "flyteadmin.labels" . }}
{{- with .Values.flyte.flyteadmin.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ---- flyteconsole ---- */}}

{{- define "flyteconsole.name" -}}
flyteconsole
{{- end -}}

{{- define "flyteconsole.selectorLabels" -}}
app.kubernetes.io/name: {{ template "flyteconsole.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flyteconsole.labels" -}}
{{ include "flyteconsole.selectorLabels" . }}
helm.sh/chart: {{ include "flyte.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flyteconsole.podLabels" -}}
{{ include "flyteconsole.labels" . }}
{{- with .Values.flyte.flyteconsole.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ---- cacheservice (already has dedicated templates, helpers referenced there) ---- */}}

{{- define "cacheservice.name" -}}
cacheservice
{{- end -}}

{{- define "cacheservice.selectorLabels" -}}
app.kubernetes.io/name: {{ template "cacheservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cacheservice.labels" -}}
{{ include "cacheservice.selectorLabels" . }}
helm.sh/chart: {{ include "flyte.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "cacheservice.podLabels" -}}
{{ include "cacheservice.labels" . }}
{{- with .Values.flyte.cacheservice.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ---- Database secret volume helpers ---- */}}

{{- define "databaseSecret.volume" -}}
{{- with .Values.flyte.common.databaseSecret.name -}}
- name: {{ . }}
  secret:
    secretName: {{ . }}
{{- end }}
{{- end }}

{{- define "databaseSecret.volumeMount" -}}
{{- with .Values.flyte.common.databaseSecret.name -}}
- mountPath: /etc/db
  name: {{ . }}
{{- end }}
{{- end }}

{{/* cacheservice uses the same pattern but was historically separate */}}
{{- define "cacheservice-databaseSecret.volume" -}}
{{- with .Values.flyte.common.databaseSecret.name -}}
- name: {{ . }}
  secret:
    secretName: {{ . }}
{{- end }}
{{- end }}

{{- define "cacheservice-databaseSecret.volumeMount" -}}
{{- with .Values.flyte.common.databaseSecret.name -}}
- mountPath: /etc/db
  name: {{ . }}
{{- end }}
{{- end }}

{{/* ---- Storage helpers (from flyte-core _helpers.tpl) ---- */}}

{{- define "storage.base" -}}
storage:
{{- if eq .Values.flyte.storage.type "s3" }}
  type: s3
  container: {{ .Values.flyte.storage.bucketName | quote }}
  connection:
    auth-type: {{ .Values.flyte.storage.s3.authType }}
    region: {{ .Values.flyte.storage.s3.region }}
    {{- if .Values.flyte.storage.s3.endpoint }}
    endpoint: {{ .Values.flyte.storage.s3.endpoint }}
    {{- end }}
    {{- if eq .Values.flyte.storage.s3.authType "accesskey" }}
    access-key: {{ .Values.flyte.storage.s3.accessKey }}
    secret-key: {{ .Values.flyte.storage.s3.secretKey }}
    {{- end }}
{{- else if eq .Values.flyte.storage.type "gcs" }}
  type: stow
  stow:
    kind: google
    config:
      json: ""
      project_id: {{ .Values.flyte.storage.gcs.projectId }}
      scopes: https://www.googleapis.com/auth/cloud-platform
  container: {{ .Values.flyte.storage.bucketName | quote }}
{{- else if eq .Values.flyte.storage.type "sandbox" }}
  type: minio
  container: {{ .Values.flyte.storage.bucketName | quote }}
  stow:
    kind: s3
    config:
      access_key_id: minio
      auth_type: accesskey
      secret_key: miniostorage
      disable_ssl: true
      endpoint: http://minio.{{ .Release.Namespace }}.svc.cluster.local:9000
      region: us-east-1
  signedUrl:
    stowConfigOverride:
      endpoint: http://minio.{{ .Release.Namespace }}.svc.cluster.local:9000
{{- else if eq .Values.flyte.storage.type "custom" }}
{{- with .Values.flyte.storage.custom -}}
  {{ tpl (toYaml .) $ | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "storage" -}}
{{ include "storage.base" .}}
  enable-multicontainer: {{ .Values.flyte.storage.enableMultiContainer }}
  limits:
    maxDownloadMBs: {{ .Values.flyte.storage.limits.maxDownloadMBs }}
  cache:
    max_size_mbs: {{ .Values.flyte.storage.cache.maxSizeMBs }}
    target_gc_percent: {{ .Values.flyte.storage.cache.targetGCPercent }}
{{- end }}
