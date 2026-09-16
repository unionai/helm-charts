{{- define "operator.billing.defaultModel" -}}
{{- if .Release.IsUpgrade -}}
  {{- $error := "Cannot preserve installed billing model: set config.operator.billing.model explicitly to None, Legacy, Shadow, or ResourceUsage (use --dry-run=server for an upgrade preview)." -}}
  {{- $previous := lookup "v1" "ConfigMap" .Release.Namespace (include "union-operator.fullname" .) -}}
  {{- if not $previous -}}
    {{- fail $error -}}
  {{- end -}}
  {{- $data := get $previous "data" | default dict -}}
  {{- $config := fromYaml (get $data "config.yaml" | default "") -}}
  {{- $operator := get $config "operator" | default dict -}}
  {{- if not (kindIs "map" $operator) -}}
    {{- fail $error -}}
  {{- end -}}
  {{- $billing := get $operator "billing" | default dict -}}
  {{- if not (kindIs "map" $billing) -}}
    {{- fail $error -}}
  {{- end -}}
  {{- $model := get $billing "model" -}}
  {{- if not (has $model (list "None" "Legacy" "Shadow" "ResourceUsage")) -}}
    {{- fail $error -}}
  {{- end -}}
  {{- $model -}}
{{- else -}}
  ResourceUsage
{{- end -}}
{{- end -}}

{{- define "operator.billing.config" -}}
{{- $billing := deepCopy (.Values.config.operator.billing | default dict) -}}
{{- if not (kindIs "map" $billing) -}}
  {{- fail "config.operator.billing must be a mapping with a model" -}}
{{- end -}}
{{- $rawModel := get $billing "model" -}}
{{- $model := "" -}}
{{- /* --reuse-values can retain the previous chart's tunnel-dependent default. */ -}}
{{- $legacyDefault := `{{ ternary "ResourceUsage" "None" .Values.operator.enableTunnelService }}` -}}
{{- if or (eq (toString $rawModel) "") (eq (toString $rawModel) $legacyDefault) -}}
  {{- $model = include "operator.billing.defaultModel" . -}}
{{- else -}}
  {{- $model = tpl (toString $rawModel) . -}}
{{- end -}}
{{- if not (has $model (list "None" "Legacy" "Shadow" "ResourceUsage")) -}}
  {{- fail "config.operator.billing.model must resolve to None, Legacy, Shadow, or ResourceUsage" -}}
{{- end -}}
{{- $_ := set $billing "model" $model -}}
{{- tpl (toYaml $billing) . -}}
{{- end -}}
