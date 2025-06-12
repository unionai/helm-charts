{{- define "unionai.imagePullSecrets" -}}
{{- if and (hasKey .config "imagePullSecrets") }}
{{ toYaml .config.imagePullSecrets }}
{{- else if and (hasKey .Values "imagePullSecrets") }}
{{ toYaml .Values.imagePullSecrets }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.resources" -}}
{{- if and (hasKey .config "resources") }}
{{ toYaml .config.resources }}
{{- else if and (hasKey .Values "resources") }}
{{ toYaml .Values.resources }}
{{- end }}
{{- end }}

{{- define "unionai.nodeSelector" -}}
{{- if and (hasKey .config "nodeSelector") }}
{{ toYaml .config.nodeSelector }}
{{- else if and (hasKey .Values "nodeSelector") }}
{{ toYaml .Values.nodeSelector }}
{{- end }}
{{- end }}

{{- define "unionai.service" -}}
{{- if and (hasKey .config "service") }}
{{ toYaml .config.service }}
{{- else if and (hasKey .Values "service") }}
{{ toYaml .Values.service }}
{{- end }}
{{- end }}


{{- define "unionai.affinity" -}}
{{- if and (hasKey .config "affinity") }}
{{ toYaml .config.affinity }}
{{- else if and (hasKey .Values "affinity") }}
{{ toYaml .Values.affinity }}
{{- end }}
{{- end }}

{{- define "unionai.tolerations" -}}
{{- if and (hasKey .config "tolerations") }}
{{ toYaml .config.tolerations }}
{{- else if and (hasKey .Values "tolerations") }}
{{ toYaml .Values.tolerations }}
{{- end }}
{{- end }}

{{- define "unionai.env" -}}
{{- if and (hasKey .config "env") -}}
{{- toYaml .config.env -}}
{{- else if and (hasKey .Values "env") }}
{{- toYaml .Values.env -}}
{{- end }}
{{- end }}

{{- define "unionai.securityContext" -}}
{{- if and (hasKey .config "securityContext") }}
    {{- toYaml .config.securityContext -}}
{{- else if and (hasKey .Values "securityContext") }}
    {{- toYaml .Values.securityContext -}}
{{- end }}
{{- end }}

{{- define "unionai.podSecurityContext" -}}
{{- if and (hasKey .config "podSecurityContext") .config.podSecurityContext }}
    {{- toYaml .config.podSecurityContext }}
{{- else if and (hasKey .Values "podSecurityContext") .Values.podSecurityContext }}
    {{- toYaml .Values.podSecurityContext }}
{{- end }}
{{- end }}


{{- define "unionai.serviceAccount.create" -}}
{{- if and (hasKey .config "serviceAccount") (hasKey .config.serviceAccount "create") }}
{{ .config.serviceAccount.create }}
{{- else if and (hasKey .Values "serviceAccount") (hasKey .Values.serviceAccount "create") }}
{{ .Values.serviceAccount.create }}
{{- else }}
false
{{- end }}
{{- end }}

{{- define "unionai.serviceAccount.annotations" -}}
{{- if and (hasKey .config "serviceAccount") (hasKey .config.serviceAccount "annotations") }}
{{- toYaml .config.serviceAccount.annotations }}
{{- else if and (hasKey .Values "serviceAccount") (hasKey .Values.serviceAccount "annotations") }}
{{- toYaml .Values.serviceAccount.annotations }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.replicaCount" -}}
{{- if and (hasKey .config "replicaCount") }}
{{ .config.replicaCount }}
{{- else if and (hasKey .Values "replicaCount") }}
{{ .Values.replicaCount }}
{{- else }}
1
{{- end }}
{{- end }}

{{- define "unionai.image.repository" -}}
{{- if and (hasKey .config "image") (hasKey .config.image "repository") }}
{{ .config.image.repository }}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "repository") }}
{{ .Values.image.repository }}
{{- else }}
""
{{- end }}
{{- end }}

{{- define "unionai.image.tag" -}}
{{- if and (hasKey .config "image") (hasKey .config.image "tag") }}
{{ .config.image.tag }}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "tag") }}
{{ .Values.image.tag }}
{{- else }}
""
{{- end }}
{{- end }}

{{- define "unionai.podAnnotations" -}}
{{- if and (hasKey .config "podAnnotations") }}
{{ toYaml .config.podAnnotations }}
{{- else if and (hasKey .Values "podAnnotations") }}
{{ toYaml .Values.podAnnotations }}
{{- else }}
null
{{- end }}
{{- end }}

{{- define "unionai.podMonitor" -}}
{{- if and (hasKey .config "podMonitor") }}
{{ .config.podMonitor }}
{{- else if and (hasKey .Values "podMonitor") }}
{{ .Values.podMonitor }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.serviceProfile" -}}
{{- if and (hasKey .config "serviceProfile") }}
{{ .config.serviceProfile }}
{{- else if and (hasKey .Values "serviceProfile") }}
{{ .Values.serviceProfile }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.autoscaling" -}}
{{- if and (hasKey .config "autoscaling") }}
{{ toYaml .config.autoscaling }}
{{- else if and (hasKey .Values "autoscaling") }}
{{ toYaml .Values.autoscaling }}
{{- end }}
{{- end }}

{{- define "unionai.spreadConstraints" -}}
{{- if and (hasKey .config "spreadConstraints") }}
{{ .config.spreadConstraints }}
{{- else if and (hasKey .Values "spreadConstraints") }}
{{ .Values.spreadConstraints }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.probe" -}}
{{- if and (hasKey .config "probe") }}
{{ .config.probe }}
{{- else if and (hasKey .Values "probe") }}
{{ .Values.probe }}
{{- else }}
{}
{{- end }}
{{- end }}


{{- define "unionai.name" -}}
{{- .key | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "unionai.fullname" -}}
{{- if .config.fullnameOverride }}
{{- .config.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" $.Release.Name .name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "unionai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "unionai.labels" -}}
helm.sh/chart: {{ include "unionai.chart" . }}
{{ include "unionai.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}


{{- define "unionai.namespace" -}}
{{- default .Release.Namespace .Values.forceNamespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "unionai.secretName" -}}
{{- if .config.secretNameOverride }}
{{- .config.secretNameOverride | trunc 63 | trimSuffix "-" }}
{{- else if and (hasKey .Values "service") (hasKey .Values.service "secretName") }}
{{- .Values.service.secretName }}
{{- else }}
{{- include "unionai.fullname" . | trim -}}
{{- end }}
{{- end }}

{{- define "unionai.dbSecretName" -}}
{{- if .config.dbSecretNameOverride -}}
{{- .config.dbSecretNameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if and (hasKey .Values "service") (hasKey .Values.service "dbSecretName") -}}
{{- .Values.service.dbSecretName -}}
{{- else -}}
db-pass
{{- end -}}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "unionai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "unionai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "unionai.image" -}}
{{- $repo := "" }}
{{- $tag := "" }}

{{- if and (hasKey .config "image") (hasKey .config.image "repository") }}
  {{- $repo = .config.image.repository }}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "repository") }}
  {{- $repo = .Values.image.repository }}
{{- end }}

{{- if and (hasKey .config "image") (hasKey .config.image "tag") }}
  {{- $tag = .config.image.tag }}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "tag") }}
  {{- $tag = .Values.image.tag }}
{{- else if hasKey .Chart "AppVersion" }}
  {{- $tag = .Chart.AppVersion }}
{{- end }}

{{- if and $repo $tag }}
{{ printf "%s:%s" $repo $tag }}
{{- else if $repo }}
{{ $repo }}
{{- else }}
""  # empty string to avoid template error
{{- end }}
{{- end }}

{{- define "unionai.serviceAccountName" -}}
{{- if eq (include "unionai.serviceAccount.create" . | trim) "true" }}
  {{- if and (hasKey .config "serviceAccount") (hasKey .config.serviceAccount "name") }}
{{ .config.serviceAccount.name }}
  {{- else if and (hasKey .Values "serviceAccount") (hasKey .Values.serviceAccount "name") }}
{{ .Values.serviceAccount.name }}
  {{- else }}
{{- include "unionai.fullname" . | trim -}}
  {{- end }}
{{- else }}
default
{{- end }}
{{- end }}

{{- define "unionai.sharedService" -}}
{{- if and (hasKey .config "sharedService") }}
{{ .config.sharedService }}
{{- else if and (hasKey .Values "sharedService") }}
{{ .Values.sharedService }}
{{- else }}
{}
{{- end }}
{{- end }}

{{- define "unionai.sync" -}}
{{- if and (hasKey .config "sync") }}
{{ .config.sync }}
{{- else if and (hasKey .Values "sync") }}
{{ .Values.sync }}
{{- else }}
{}
{{- end }}
{{- end }}


{{- define "unionai.imagePullPolicy" -}}
{{- if and (hasKey .config "image") (hasKey .config.image "pullPolicy") }}
{{ .config.image.pullPolicy }}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "pullPolicy") }}
{{ .Values.image.pullPolicy }}
{{- else }}
IfNotPresent
{{- end }}
{{- end }}

{{- define "unionai.strategy" -}}
{{- if and (hasKey .config "strategy") .config.strategy }}
{{ toYaml .config.strategy }}
{{- else if and (hasKey .Values "strategy") .Values.strategy }}
{{ toYaml .Values.strategy }}
{{- end }}
{{- end }}


{{- define "unionai.deepMerge" -}}
{{- $dest := deepCopy .dest -}}
{{- $source := .source -}}

{{- range $key, $value := $source }}
  {{- if hasKey $dest $key }}
    {{- if and (kindIs "map" (get $dest $key)) (kindIs "map" $value) }}
      {{- $_ := set $dest $key (include "unionai.deepMerge" (dict "dest" (get $dest $key) "source" $value) | fromYaml) }}
    {{- else }}
      {{- $_ := set $dest $key $value }}
    {{- end }}
  {{- else }}
    {{- $_ := set $dest $key $value }}
  {{- end }}
{{- end }}

{{- toYaml $dest }}
{{- end }}


{{- define "unionai.configMap" -}}
{{- $global := dict }}
{{- $svc := dict }}

{{- if hasKey .Values "configMap" }}
  {{- $global = .Values.configMap }}
{{- end }}

{{- if hasKey .config "configMap" }}
  {{- $svc = .config.configMap }}
{{- end }}

{{- $merged := (include "unionai.deepMerge" (dict "dest" $global "source" $svc) | fromYaml) }}
{{- tpl ($merged | toYaml) . }}
{{- end }}

{{/*
Renders a complete tree, even values that contains template.
*/}}
{{- define "unionai.render" -}}
  {{- if typeIs "string" .value }}
    {{- tpl .value .context }}
  {{ else }}
    {{- tpl (.value | toYaml) .context }}
  {{- end }}
{{- end -}}