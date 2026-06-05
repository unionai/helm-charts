{{/*
Connection helpers for the data-plane → control-plane path.

Single source of truth for the canonical CP endpoint expression and TLS
posture. Consumers (`config.admin.admin`, `config.catalog.catalog-cache`,
`config.k8s.plugins.k8s.default-env-vars`, `config.union.connection`,
`clusterresourcesync.config.union.connection`, etc.) reference these
helpers so the host, port, and TLS settings stay in sync across the chart.

Override surface (globals declared at the top of values.yaml):
  CONTROLPLANE_HOST           bare hostname (no scheme, no port) — required
  CONTROLPLANE_GRPC_ENDPOINT  override the default `dns:///<host>:443`
  QUEUE_GRPC_ENDPOINT         override the task-pod queue endpoint
                              (cascades from CONTROLPLANE_GRPC_ENDPOINT)
*/}}

{{- define "dataplane.cp.host" -}}
{{- $cp := tpl (default "" .Values.global.CONTROLPLANE_HOST) . -}}
{{- $legacy := tpl (default "" .Values.host) . -}}
{{- coalesce $cp $legacy -}}
{{- end -}}

{{- define "dataplane.cp.endpoint" -}}
{{- $host := include "dataplane.cp.host" . -}}
{{- $defaultEp := "" -}}
{{- if $host -}}{{- $defaultEp = printf "dns:///%s:443" $host -}}{{- end -}}
{{- default $defaultEp (tpl (default "" .Values.global.CONTROLPLANE_GRPC_ENDPOINT) .) -}}
{{- end -}}

{{- define "dataplane.cp.queueEndpoint" -}}
{{- default (include "dataplane.cp.endpoint" .) (tpl (default "" .Values.global.QUEUE_GRPC_ENDPOINT) .) -}}
{{- end -}}

{{/*
TLS posture for CP nginx (terminates TLS on 443 regardless of topology;
selfhosted cert is self-signed). Per-consumer YAML literals — bool field
spelling varies across config schemas (insecure vs insecure-skip-verify
vs insecureSkipVerify) and YAML/Go-config bool coercion through helm
template strings is fragile, so callers write the booleans inline.
*/}}
