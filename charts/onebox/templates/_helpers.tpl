{{- define "onebox.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "onebox.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "onebox.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "onebox.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "onebox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "onebox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "onebox.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "onebox.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "onebox.dbSecretName" -}}
{{- default (printf "%s-db" (include "onebox.fullname" .)) .Values.database.existingSecret }}
{{- end }}

{{- define "onebox.dbSecretKey" -}}
{{- if .Values.database.existingSecret }}{{ .Values.database.existingSecretKey }}{{ else }}password{{ end }}
{{- end }}

{{/* Cluster DNS name of the Service, which task pods call back to. The short
<svc>.<ns>.svc form: onebox treats *.svc.cluster.local as its own internal
traffic. */}}
{{- define "onebox.serviceHost" -}}
{{- printf "%s.%s.svc" (include "onebox.fullname" .) .Release.Namespace }}
{{- end }}

{{- define "onebox.bucketURI" -}}
{{- $scheme := dict "s3" "s3" "gcs" "gs" "azure" "abfs" }}
{{- printf "%s://%s" (get $scheme .Values.storage.type) .Values.storage.bucket }}
{{- end }}

{{/* flytestdlib storage section. */}}
{{- define "onebox.storage" -}}
{{- $s := .Values.storage }}
type: stow
container: {{ $s.bucket | quote }}
enable-multicontainer: true
stow:
{{- if eq $s.type "s3" }}
  kind: s3
  config:
    region: {{ $s.region | quote }}
    # Credentials come from the pod: IRSA / pod identity, or AWS_* env vars
    # from storage.existingSecret.
    auth_type: iam
    {{- with $s.endpoint }}
    endpoint: {{ . | quote }}
    disable_ssl: {{ hasPrefix "http://" . }}
    {{- end }}
{{- else if eq $s.type "gcs" }}
  kind: google
  config:
    json: ""
    project_id: {{ $s.gcpProjectId | quote }}
    scopes: https://www.googleapis.com/auth/cloud-platform
{{- else if eq $s.type "azure" }}
  kind: azure
  config:
    account: {{ $s.azureAccount | quote }}
{{- else }}
{{- fail (printf "storage.type must be s3, gcs or azure, got %q" $s.type) }}
{{- end }}
{{- end }}

{{- define "onebox.internalSecretName" -}}
{{- default (printf "%s-internal" (include "onebox.fullname" .)) .Values.internalSecret.existingSecret }}
{{- end }}

{{/* bundled.enabled: point database and storage at the bundled Postgres and
S3 store. Included at the top of every template that reads them; setting the
same values again is harmless. */}}
{{- define "onebox.bundled" -}}
{{- if .Values.bundled.enabled }}
{{- $name := include "onebox.fullname" . }}
{{- $_ := set .Values.database "host" (printf "%s-postgres" $name) }}
{{- $_ = set .Values.database "port" 5432 }}
{{- $_ = set .Values.database "name" "union" }}
{{- $_ = set .Values.database "user" "union" }}
{{- $_ = set .Values.database "sslMode" "disable" }}
{{- $_ = set .Values.database "password" .Values.bundled.postgres.password }}
{{- $_ = set .Values.database "existingSecret" "" }}
{{- $_ = set .Values.storage "type" "s3" }}
{{- $_ = set .Values.storage "bucket" .Values.bundled.s3.bucket }}
{{- $_ = set .Values.storage "region" "us-east-1" }}
{{- $_ = set .Values.storage "endpoint" (default (printf "http://%s-s3.%s.svc:4566" $name .Release.Namespace) .Values.bundled.s3.endpoint) }}
{{- $_ = set .Values.storage "authType" "accesskey" }}
{{- $_ = set .Values.storage "existingSecret" (printf "%s-s3" $name) }}
{{- end }}
{{- end }}
