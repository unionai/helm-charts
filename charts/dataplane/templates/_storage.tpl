
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
{{- with .Values.storage.fastRegistrationURL -}}
  signedURL:
    stowConfigOverride:
      endpoint: {{- (toYaml .) }}
{{- end }}
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
  container: {{ .Values.storage.bucketName }}
{{- include "storage.base" .}}
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
