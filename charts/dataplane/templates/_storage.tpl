
{{/*
Storage helpers.  This migrates all of the storage configurations to
the stow based options to provide additional configuration flexibility.
*/}}
{{- define "storage.base" -}}
{{- if or (eq .Values.storage.provider "compat") (eq .Values.storage.provider "oci") }}
  type: stow
  stow:
    kind: s3
    config:
      auth_type: accesskey
      access_key_id: {{ .Values.storage.accessKey }}
      secret_key: {{ .Values.storage.secretKey }}
      disable_ssl: {{ .Values.storage.disableSSL }}
      endpoint: {{ .Values.storage.endpoint }}
      region: {{ .Values.storage.region }}
{{- with .Values.storage.fastRegistrationURL }}
  signedURL:
    stowConfigOverride:
      endpoint: {{ . }}
{{- end }}
{{- else if eq .Values.storage.provider "aws" }}
  type: s3
  connection:
    auth-type: {{ .Values.storage.authType }}
    region: {{ .Values.storage.region }}
    {{- if eq .Values.storage.authType "accesskey" }}
    access-key: {{ .Values.storage.accessKey }}
    secret-key: {{ .Values.storage.secretKey }}
    {{- end }}
{{- else if eq .Values.storage.provider "gcs" }}
  type: stow
  stow:
      kind: google
      config:
        json: ""
        project_id: {{ required "GCP project required for GCS storage provider" .Values.storage.gcp.projectId }}
        scopes: https://www.googleapis.com/auth/cloud-platform
{{- else if eq .Values.storage.provider "custom" }}
{{- with .Values.storage.custom -}}
  {{ tpl (toYaml .) $ | nindent 2 }}
{{- end }}
{{- else }}
{{- fail "invalid provider" }}
{{- end }}
{{- end }}

{{- define "storage" -}}
storage:
  container: {{ tpl .Values.storage.bucketName . | quote }}
{{- include "storage.base" . }}
  enable-multicontainer: {{ .Values.storage.enableMultiContainer }}
  limits:
    maxDownloadMBs: {{ .Values.storage.limits.maxDownloadMBs }}
  cache:
    max_size_mbs: {{ .Values.storage.cache.maxSizeMBs }}
    target_gc_percent: {{ .Values.storage.cache.targetGCPercent }}
{{- end }}

{{- define "fast-registration-storage" -}}
fastRegistrationStorage:
  container: {{ .Values.storage.fastRegistrationBucketName | quote}}
{{- include "storage.base" .}}
{{- end }}

{{- define "storage.metadata-prefix" -}}
{{- if .Values.storage.metadataPrefix -}}
{{ tpl .Values.storage.metadataPrefix . -}}
{{- else if eq .Values.storage.provider "compat" -}}
s3://{{ tpl .Values.storage.bucketName . -}}
{{- else if eq .Values.storage.provider "oci" -}}
oci://{{ tpl .Values.storage.bucketName . -}}
{{- else if eq .Values.storage.provider "aws" -}}
s3://{{ tpl .Values.storage.bucketName . -}}
{{- else if eq .Values.storage.provider "azure" -}}
azblob://{{ tpl .Values.storage.bucketName . -}}
{{- else if eq .Values.storage.provider "gcs" -}}
gs://{{ tpl .Values.storage.bucketName . -}}
{{- else if eq .Values.storage.provider "custom" -}}
s3://{{ tpl .Values.storage.bucketName . -}}
{{- else -}}
{{- fail "invalid provider" -}}
{{- end -}}
{{- end -}}