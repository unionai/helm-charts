
{{/*
Storage helpers.  This migrates all of the storage configurations to
the stow based options to provide additional configuration flexibility.
*/}}

{{/*
storage.credentialsFromSecretRef is "true" when the object store's access keys can reach pods at
runtime from the customer's Secret (env valueFrom.secretKeyRef) instead of being copied into
rendered config: credentialsSecretRef names a Secret in the release namespace. A pod cannot
reference a Secret in another namespace, so one elsewhere keeps the render-time copy.
*/}}
{{- define "storage.credentialsFromSecretRef" -}}
{{- $ref := .Values.storage.credentialsSecretRef -}}
{{- if and $ref.name (or (not $ref.namespace) (eq $ref.namespace .Release.Namespace)) -}}true{{- end -}}
{{- end -}}

{{/*
storage.credentialsEnv is the AWS_* env a platform container needs to reach the object store when
its storage config uses auth_type iam: the AWS SDK's default chain reads these variables, so the
keys stay in the Secret. Empty unless storage.credentialsFromSecretRef.
*/}}
{{- define "storage.credentialsEnv" -}}
{{- if include "storage.credentialsFromSecretRef" . }}
{{- $ref := .Values.storage.credentialsSecretRef }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $ref.name | quote }}
      key: {{ $ref.accessKeyIdKey | default "access_key_id" | quote }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $ref.name | quote }}
      key: {{ $ref.secretKeyKey | default "secret_key" | quote }}
{{- end }}
{{- end -}}

{{/*
storage.taskCredentialsFromPodTemplate is "true" when task pods get the object store's keys as
FLYTE_AWS_* env from the Secret, set on the task-template PodTemplate (common/task-podtemplate.yaml)
rather than as literal default-env-vars. Task pods must run in the release namespace to reference
the Secret, so this needs single-namespace mode as well as storage.credentialsFromSecretRef.
*/}}
{{- define "storage.taskCredentialsFromPodTemplate" -}}
{{- if and (include "storage.credentialsFromSecretRef" .) (include "singleNamespace" .) -}}true{{- end -}}
{{- end -}}

{{- define "storage.base" -}}
{{- if or (eq .Values.storage.provider "compat") (eq .Values.storage.provider "oci") }}
  type: stow
  stow:
    kind: s3
    config:
      {{- if include "storage.credentialsFromSecretRef" . }}
      # The access keys reach each pod as AWS_* env from credentialsSecretRef
      # (storage.credentialsEnv); iam makes the client read them from there.
      auth_type: iam
      {{- else }}
      auth_type: accesskey
      {{- end }}
      {{- if include "storage.credentialsFromSecretRef" . }}
      {{- else if .Values.storage.credentialsSecretRef.name }}
      {{- $secret := lookup "v1" "Secret" (.Values.storage.credentialsSecretRef.namespace | default .Release.Namespace) .Values.storage.credentialsSecretRef.name }}
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
      {{- if and (eq .Values.storage.authType "accesskey") (include "storage.credentialsFromSecretRef" .) }}
      # The access keys reach each pod as AWS_* env from credentialsSecretRef.
      auth_type: iam
      {{- else }}
      auth_type: {{ .Values.storage.authType }}
      {{- end }}
      region: {{ .Values.storage.region }}
      {{- if and (eq .Values.storage.authType "accesskey") (not (include "storage.credentialsFromSecretRef" .)) }}
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

  {{- if and (include "storage.credentialsFromSecretRef" .) (eq $customType "stow") (eq $stowKind "s3") -}}
    {{- /* The keys reach each pod as AWS_* env; iam makes the client read them from there. */ -}}
    {{- $mergedStowConfig := omit (mergeOverwrite (deepCopy $stowConfig) (dict "auth_type" "iam")) "access_key_id" "secret_key" -}}
    {{- $_ := set $stow "config" $mergedStowConfig -}}
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