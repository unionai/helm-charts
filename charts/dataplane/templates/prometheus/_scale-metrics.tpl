{{- /*
Scale's series (scale_*) stay in the data plane. The chart's own prometheus ConfigMap
(configmap.yaml) adds a drop of scale_.* to every remote_write it renders. Two remote_writes are
rendered by subcharts straight from the values, so the chart cannot add the drop there:

- kube-prometheus-stack's, monitoring.prometheus.prometheusSpec.remoteWrite (when monitoring is on);
- the upstream prometheus ConfigMap's, prometheus.server.remoteWrite, when
  prometheus.server.configMapOverrideName is emptied.

Both Prometheus servers scrape the operator proxy's debug port, so a queue there without the drop
ships scale_* out. NOTES.txt names each such queue. It warns and never fails the render (owner
decision 2026-11-13 18:08 IST). Checked by tests/test-metrics-drop.sh.
*/ -}}

{{- /* "true" when the rules list (dict "rules" <list> "key" <source labels key>) holds the drop:
       action drop, regex scale_.*, source labels [__name__]. */ -}}
{{- define "dataplane.scaleMetrics.hasDrop" -}}
{{- $key := .key }}
{{- $found := false }}
{{- $rules := .rules }}
{{- if not (kindIs "slice" $rules) }}{{ $rules = list }}{{ end }}
{{- range $r := $rules }}
{{- if kindIs "map" $r }}
{{- if and (eq (lower (toString (get $r "action"))) "drop") (eq (toString (get $r "regex")) "scale_.*") (eq (toString (get $r $key)) "[__name__]") }}
{{- $found = true }}
{{- end }}
{{- end }}
{{- end }}
{{- if $found }}true{{ end }}
{{- end -}}

{{- /* One line per remote_write that would ship scale_* metrics: "<values path>[i] <url>". */ -}}
{{- define "dataplane.scaleMetrics.leaks" -}}
{{- $mon := .Values.monitoring | default dict }}
{{- if and $mon.enabled (dig "prometheus" "enabled" true $mon) }}
{{- $kpQueues := dig "prometheus" "prometheusSpec" "remoteWrite" list $mon }}
{{- if not (kindIs "slice" $kpQueues) }}{{ $kpQueues = list }}{{ end }}
{{- range $i, $rw := $kpQueues }}
{{- if not (kindIs "map" $rw) }}{{ $rw = dict }}{{ end }}
{{- if not (include "dataplane.scaleMetrics.hasDrop" (dict "rules" (get $rw "writeRelabelConfigs") "key" "sourceLabels")) }}
- monitoring.prometheus.prometheusSpec.remoteWrite[{{ $i }}] {{ get $rw "url" }}
{{- end }}
{{- end }}
{{- end }}
{{- $prom := .Values.prometheus | default dict }}
{{- $server := $prom.server | default dict }}
{{- if and $prom.enabled (not $server.configMapOverrideName) }}
{{- $queues := $server.remoteWrite }}
{{- if not (kindIs "slice" $queues) }}{{ $queues = list }}{{ end }}
{{- range $i, $rw := $queues }}
{{- if not (kindIs "map" $rw) }}{{ $rw = dict }}{{ end }}
{{- if not (include "dataplane.scaleMetrics.hasDrop" (dict "rules" (get $rw "write_relabel_configs") "key" "source_labels")) }}
- prometheus.server.remoteWrite[{{ $i }}] {{ get $rw "url" }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
