
{{/*
Storage helpers.  This migrates all of the storage configurations to
the stow based options to provide additional configuration flexibility.
*/}}

{{/*
storage.credentialsFromEnv: "true" when storage keys come from credentialsSecretRef
as env (secretKeyRef) instead of being rendered into ConfigMaps.
*/}}
{{- define "storage.credentialsFromEnv" -}}
{{- if and .Values.storage.credentialsSecretRef.name (eq (.Values.storage.credentialsSecretRef.mode | default "lookup") "env") -}}
{{- if and .Values.storage.credentialsSecretRef.namespace (ne .Values.storage.credentialsSecretRef.namespace .Release.Namespace) -}}
{{- fail "storage.credentialsSecretRef.mode=env needs the Secret in the release namespace (secretKeyRef cannot cross namespaces)" -}}
{{- end -}}
{{- if not (include "singleNamespace" .) -}}
{{- fail "storage.credentialsSecretRef.mode=env requires single-namespace mode (task pods reference the Secret from the release namespace)" -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
storage.credentialEnvs: env entries that source the storage keys from
credentialsSecretRef (mode=env). Both the AWS default-chain names (Go
components, stow auth_type iam) and the FLYTE_AWS_* names (the Python SDK).
*/}}
{{- define "storage.credentialEnvs" -}}
{{- if include "storage.credentialsFromEnv" . }}
{{- $ref := .Values.storage.credentialsSecretRef }}
{{- range $name, $key := dict "AWS_ACCESS_KEY_ID" ($ref.accessKeyIdKey | default "access_key_id") "AWS_SECRET_ACCESS_KEY" ($ref.secretKeyKey | default "secret_key") "FLYTE_AWS_ACCESS_KEY_ID" ($ref.accessKeyIdKey | default "access_key_id") "FLYTE_AWS_SECRET_ACCESS_KEY" ($ref.secretKeyKey | default "secret_key") }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.name }}
      key: {{ $key }}
{{- end }}
{{- with $.Values.storage.region }}
- name: AWS_REGION
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "storage.base" -}}
{{- if or (eq .Values.storage.provider "compat") (eq .Values.storage.provider "oci") }}
  type: stow
  stow:
    kind: s3
    config:
      {{- if include "storage.credentialsFromEnv" . }}
      auth_type: iam
      {{- else }}
      auth_type: accesskey
      {{- if .Values.storage.credentialsSecretRef.name }}
      {{- $secret := lookup "v1" "Secret" (.Values.storage.credentialsSecretRef.namespace | default .Release.Namespace) .Values.storage.credentialsSecretRef.name }}
      {{- if $secret }}
      access_key_id: {{ index $secret.data (.Values.storage.credentialsSecretRef.accessKeyIdKey | default "access_key_id") | b64dec | quote }}
      secret_key: {{ index $secret.data (.Values.storage.credentialsSecretRef.secretKeyKey | default "secret_key") | b64dec | quote }}
      {{- end }}
      {{- else }}
      access_key_id: {{ .Values.storage.accessKey }}
      secret_key: {{ .Values.storage.secretKey }}
      {{- end }}
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
      auth_type: {{ ternary "iam" .Values.storage.authType (eq (include "storage.credentialsFromEnv" .) "true") }}
      region: {{ .Values.storage.region }}
      {{- if and (eq .Values.storage.authType "accesskey") (not (include "storage.credentialsFromEnv" .)) }}
      {{- if .Values.storage.credentialsSecretRef.name }}
      {{- $secret := lookup "v1" "Secret" (.Values.storage.credentialsSecretRef.namespace | default .Release.Namespace) .Values.storage.credentialsSecretRef.name }}
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

  {{- if and (include "storage.credentialsFromEnv" .) (eq $customType "stow") (eq $stowKind "s3") -}}
    {{- $envStowConfig := omit (deepCopy $stowConfig) "access_key_id" "secret_key" -}}
    {{- $_ := set $envStowConfig "auth_type" "iam" -}}
    {{- $_ := set $stow "config" $envStowConfig -}}
    {{- $_ := set $custom "stow" $stow -}}
  {{- else if and .Values.storage.credentialsSecretRef.name (eq $customType "stow") (eq $stowKind "s3") -}}
    {{- $secret := lookup "v1" "Secret" (.Values.storage.credentialsSecretRef.namespace | default .Release.Namespace) .Values.storage.credentialsSecretRef.name -}}
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
{{- /* A custom provider block may carry its own container key; rendering the default alongside it would emit a
       duplicate mapping key, which strict YAML parsers reject. The custom value wins. */}}
{{- $customHasContainer := and (eq .Values.storage.provider "custom") (hasKey (default dict .Values.storage.custom) "container") -}}
storage:
{{- if not $customHasContainer }}
  container: {{ tpl .Values.storage.bucketName . | quote }}
{{- end }}
{{- include "storage.base" . }}
  enable-multicontainer: {{ .Values.storage.enableMultiContainer }}
  limits:
    maxDownloadMBs: {{ .Values.storage.limits.maxDownloadMBs }}
  cache:
    max_size_mbs: {{ .Values.storage.cache.maxSizeMBs }}
    target_gc_percent: {{ .Values.storage.cache.targetGCPercent }}
{{- end }}

{{- define "fast-registration-storage" -}}
{{- $customHasContainer := and (eq .Values.storage.provider "custom") (hasKey (default dict .Values.storage.custom) "container") -}}
fastRegistrationStorage:
{{- if not $customHasContainer }}
  container: {{ .Values.storage.fastRegistrationBucketName | quote}}
{{- end }}
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