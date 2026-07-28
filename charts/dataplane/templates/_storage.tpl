
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
      {{- if .Values.storage.credentialsSecretRef.name }}
      {{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.storage.credentialsSecretRef.name }}
      {{- if $secret }}
      access_key_id: {{ index $secret.data (.Values.storage.credentialsSecretRef.accessKeyIdKey | default "access_key_id") | b64dec | quote }}
      secret_key: {{ index $secret.data (.Values.storage.credentialsSecretRef.secretKeyKey | default "secret_key") | b64dec | quote }}
      {{- end }}
      {{- else }}
      access_key_id: {{ .Values.storage.accessKey }}
      secret_key: {{ .Values.storage.secretKey }}
      {{- end }}
      disable_ssl: {{ .Values.storage.disableSSL }}
      endpoint: {{ .Values.storage.endpoint }}
      region: {{ .Values.storage.region }}
{{- with .Values.storage.fastRegistrationURL }}
  signedURL:
    stowConfigOverride:
      endpoint: {{ . }}
{{- end }}
{{- else if eq .Values.storage.provider "aws" }}
  type: stow
  stow:
    kind: s3
    config:
      auth_type: {{ .Values.storage.authType }}
      region: {{ .Values.storage.region }}
      {{- if eq .Values.storage.authType "accesskey" }}
      {{- if .Values.storage.credentialsSecretRef.name }}
      {{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.storage.credentialsSecretRef.name }}
      {{- if $secret }}
      access_key_id: {{ index $secret.data (.Values.storage.credentialsSecretRef.accessKeyIdKey | default "access_key_id") | b64dec | quote }}
      secret_key: {{ index $secret.data (.Values.storage.credentialsSecretRef.secretKeyKey | default "secret_key") | b64dec | quote }}
      {{- end }}
      {{- else }}
      access_key_id: {{ .Values.storage.accessKey }}
      secret_key: {{ .Values.storage.secretKey }}
      {{- end }}
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
  {{- $custom := deepCopy (default dict .Values.storage.custom) -}}
  {{- $customType := default "" $custom.type -}}
  {{- $stow := default dict $custom.stow -}}
  {{- $stowKind := default "" $stow.kind -}}
  {{- $stowConfig := default dict $stow.config -}}

  {{- if and .Values.storage.credentialsSecretRef.name (eq $customType "stow") (eq $stowKind "s3") -}}
    {{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.storage.credentialsSecretRef.name -}}
    {{- if $secret -}}
      {{- $secretCreds := dict
        "access_key_id" (index $secret.data (.Values.storage.credentialsSecretRef.accessKeyIdKey | default "access_key_id") | b64dec)
        "secret_key" (index $secret.data (.Values.storage.credentialsSecretRef.secretKeyKey | default "secret_key") | b64dec)
      -}}
      {{- $mergedStowConfig := mergeOverwrite (deepCopy $stowConfig) $secretCreds -}}
      {{- $_ := set $stow "config" $mergedStowConfig -}}
      {{- $_ := set $custom "stow" $stow -}}
    {{- end -}}
  {{- end -}}

  {{- if $custom }}
  {{- tpl (toYaml $custom) $ | nindent 2 }}
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