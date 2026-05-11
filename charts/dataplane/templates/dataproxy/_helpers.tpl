{{/*
Fully qualified dataproxy resource name.
Mirrors the cloud repo (operator/deploy/helm/templates/_helpers.tpl):
  {union-operator.fullname}-dataproxy.
*/}}
{{- define "dataproxy.fullname" -}}
{{- printf "%s-dataproxy" (include "union-operator.fullname" .) -}}
{{- end }}

{{/*
Envoy route entry for the dataproxy backend.
Included by gateway.extraRoutes when union.dataproxy.enable is true.
NOTE: prefix "/" is a catch-all — must be the last route in the virtual host.
*/}}
{{- define "dataproxy.envoyRoute" -}}
- match:
    prefix: "/"
  route:
    cluster: dataproxy
    timeout: 3600s
{{- end -}}

{{/*
Envoy cluster entry for the dataproxy backend.
Included by gateway.extraClusters when union.dataproxy.enable is true.
*/}}
{{- define "dataproxy.envoyCluster" -}}
- name: dataproxy
  connect_timeout: 0.25s
  type: STRICT_DNS
  lb_policy: ROUND_ROBIN
  load_assignment:
    cluster_name: dataproxy
    endpoints:
      lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: {{ include "dataproxy.fullname" . }}
                port_value: {{ .Values.union.dataproxy.service.port }}
  typed_extension_protocol_options:
    envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
      "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
      explicit_http_config:
        http2_protocol_options: {}
{{- end -}}
