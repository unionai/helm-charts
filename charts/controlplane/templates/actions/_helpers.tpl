{{/*
Actions service helpers. Actions is sharded + fronted by an Envoy router, so it
cannot use the generic .Values.services renderer; these helpers and the
templates/actions/* manifests reproduce that topology while reusing the chart's
shared conventions (image fallback, config merge, labels).
*/}}

{{- define "actions.name" -}}
actions
{{- end -}}

{{- define "actions.fullname" -}}
{{- default "actions" .Values.actions.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "actions.namespace" -}}
{{- .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "actions.selectorLabels" -}}
app.kubernetes.io/name: {{ include "actions.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "actions.labels" -}}
helm.sh/chart: {{ include "unionai.chart" . }}
{{ include "actions.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "actions.serviceAccountName" -}}
{{- if .Values.actions.serviceAccount.create -}}
{{- default (include "actions.fullname" .) .Values.actions.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.actions.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Container image. Falls back to the shared control-plane services image
(.Values.image) when actions.image repository/tag are unset.
*/}}
{{- define "actions.image" -}}
{{- $repo := "" -}}
{{- $tag := "" -}}
{{- if and (hasKey .Values.actions "image") .Values.actions.image.repository -}}
{{- $repo = tpl .Values.actions.image.repository . -}}
{{- else -}}
{{- $repo = tpl .Values.image.repository . -}}
{{- end -}}
{{- if and (hasKey .Values.actions "image") .Values.actions.image.tag -}}
{{- $tag = tpl (.Values.actions.image.tag | toString) . -}}
{{- else if .Values.image.tag -}}
{{- $tag = tpl (.Values.image.tag | toString) . -}}
{{- else -}}
{{- $tag = .Chart.AppVersion -}}
{{- end -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}

{{- define "actions.imagePullPolicy" -}}
{{- if and (hasKey .Values.actions "image") .Values.actions.image.pullPolicy -}}
{{- .Values.actions.image.pullPolicy -}}
{{- else if and (hasKey .Values "image") (hasKey .Values.image "pullPolicy") -}}
{{- .Values.image.pullPolicy -}}
{{- else -}}
IfNotPresent
{{- end -}}
{{- end -}}

{{/*
Router (Envoy) component helpers.
*/}}
{{- define "actions.router.fullname" -}}
{{- printf "%s-router" (include "actions.fullname" .) -}}
{{- end -}}

{{- define "actions.router.labels" -}}
{{ include "actions.labels" . }}
app.kubernetes.io/component: router
{{- end -}}

{{- define "actions.router.selectorLabels" -}}
{{ include "actions.selectorLabels" . }}
app.kubernetes.io/component: router
{{- end -}}

{{/*
Router image. Defaults to <IMAGE_REPOSITORY_PREFIX>/envoy-router:<appVersion>,
i.e. the separately-published Envoy image carrying
/lib/actions-service-router.so (private ECR union-cp/envoy-router, the parallel
private GAR mirror, and Harbor controlplane/envoy-router). Override on a
per-deployment basis only when needed.
*/}}
{{- define "actions.router.image" -}}
{{- if and .Values.actions.router.image .Values.actions.router.image.repository .Values.actions.router.image.tag -}}
{{ tpl .Values.actions.router.image.repository . }}:{{ .Values.actions.router.image.tag }}
{{- else -}}
{{ tpl .Values.global.IMAGE_REPOSITORY_PREFIX . }}/envoy-router:{{ .Chart.AppVersion }}
{{- end -}}
{{- end -}}

{{- define "actions.router.imagePullPolicy" -}}
{{- if and .Values.actions.router.image .Values.actions.router.image.pullPolicy -}}
{{- .Values.actions.router.image.pullPolicy -}}
{{- else -}}
IfNotPresent
{{- end -}}
{{- end -}}

{{- define "actions.router.retryPolicy" -}}
retry_policy:
  retry_on: 5xx
  num_retries: 10
  retry_back_off:
    base_interval:
      nanos: 25000000
    max_interval:
      seconds: 10
{{- end -}}

{{/*
Shard partition list (one entry per shard). Always returns valid JSON.
*/}}
{{- define "actions.shardsConfig" -}}
{{- $partitions := list -}}
{{- if .Values.actions.configMap -}}
{{- if .Values.actions.configMap.actions -}}
{{- with .Values.actions.configMap.actions.partitions -}}
{{- $partitions = . -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- dict "partitions" $partitions | toJson -}}
{{- end -}}

{{/*
Stable per-shard hash derived from the shard's partition range. Embedding it in
the Deployment/Service name means changing a shard's range rolls that shard.
*/}}
{{- define "actions.shardHash" -}}
{{- $partitions := (include "actions.shardsConfig" .Root | fromJson).partitions -}}
{{- $shardConfig := index $partitions (int .shardIndex) -}}
{{- sha256sum (toJson $shardConfig) | trunc 8 -}}
{{- end -}}

{{- define "actions.shardCount" -}}
{{- $partitions := (include "actions.shardsConfig" . | fromJson).partitions -}}
{{- len $partitions -}}
{{- end -}}

{{/*
Rendered actions config.yaml: the global .Values.configMap deep-merged with
.Values.actions.configMap (reusing the same helper the generic services use).
*/}}
{{- define "actions.configMap" -}}
{{- include "unionai.configMap" (dict "config" .Values.actions "Values" .Values "Release" .Release "Chart" .Chart) -}}
{{- end -}}

{{/*
Config checksum excluding the partition/shard layout, so a config change rolls
all shards but a partition-range change (which changes shard names) does not
double-trigger.
*/}}
{{- define "actions.configChecksum" -}}
{{- $config := dict -}}
{{- if .Values.actions.configMap -}}
{{- $config = deepCopy .Values.actions.configMap -}}
{{- if hasKey $config "actions" -}}
{{- $_ := unset (index $config "actions") "partitions" -}}
{{- end -}}
{{- end -}}
{{- sha256sum (toJson $config) -}}
{{- end -}}
