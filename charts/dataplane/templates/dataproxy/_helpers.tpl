{{/*
Fully qualified dataproxy resource name.
Mirrors the cloud repo (operator/deploy/helm/templates/_helpers.tpl):
  {union-operator.fullname}-dataproxy.
*/}}
{{- define "dataproxy.fullname" -}}
{{- printf "%s-dataproxy" (include "union-operator.fullname" .) -}}
{{- end }}

{{/*
Envoy route entry for the dataproxy backend (Connect server, port 8080).
Catch-all (prefix "/") — handles gRPC + Connect-RPC. Included by
gateway.extraRoutes when dataproxy.enabled is true.
NOTE: prefix "/" is a catch-all — must be the LAST route in the virtual host;
more specific prefix routes (see dataproxy.envoyHttpRoute) go above it.
*/}}
{{- define "dataproxy.envoyRoute" -}}
- match:
    prefix: "/"
  route:
    cluster: dataproxy
    timeout: 3600s
{{- end -}}

{{/*
Envoy route entries for the dataproxy HTTP/1.1 gateway (port 8089). These are
browser-facing reverse-proxy routes, not Connect-RPC, so they target the
dataproxy-http cluster. Must appear BEFORE dataproxy.envoyRoute (the catch-all).
  - /spark-history-server/ and /dataplane/ : reverse-proxy to operator-proxy.
  - /prometheus/cluster/ : scoped so only the ACTION_ADMINISTER_ACCOUNT-authz'd
    dataproxy handler (/prometheus/cluster/{cluster}/{path}) is edge-reachable;
    the internal no-op-authz /prometheus/org/... route stays unexposed.
Included by gateway.extraRoutes when dataproxy.enabled is true.
*/}}
{{- define "dataproxy.envoyHttpRoute" -}}
- match:
    prefix: "/spark-history-server/"
  route:
    cluster: dataproxy-http
    timeout: 3600s
- match:
    prefix: "/dataplane/"
  route:
    cluster: dataproxy-http
    timeout: 3600s
- match:
    prefix: "/prometheus/cluster/"
  route:
    cluster: dataproxy-http
    timeout: 3600s
{{ end -}}

{{/*
Envoy cluster entry for the dataproxy backend (Connect server, port 8080, HTTP/2).
Included by gateway.extraClusters when dataproxy.enabled is true.
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
                port_value: {{ .Values.dataproxy.service.port }}
  typed_extension_protocol_options:
    envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
      "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
      explicit_http_config:
        http2_protocol_options: {}
{{ end -}}

{{/*
Envoy cluster entry for the dataproxy HTTP/1.1 gateway (port 8089). Hosts the
browser-facing reverse-proxy routes (/spark-history-server/, /dataplane/,
/prometheus/cluster/). No http2_protocol_options -> HTTP/1.1 upstream.
Included by gateway.extraClusters when dataproxy.enabled is true.
*/}}
{{- define "dataproxy.envoyHttpCluster" -}}
- name: dataproxy-http
  connect_timeout: 0.25s
  type: STRICT_DNS
  lb_policy: ROUND_ROBIN
  load_assignment:
    cluster_name: dataproxy-http
    endpoints:
      lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: {{ include "dataproxy.fullname" . }}
                port_value: {{ .Values.dataproxy.service.httpPort }}
{{- end -}}

{{/*
Selector labels for the dataproxy workload.
*/}}
{{- define "dataproxy.selectorLabels" -}}
app.kubernetes.io/name: union-dataproxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Full label set for dataproxy resources (Deployment, Service, ServiceAccount).
*/}}
{{- define "dataproxy.labels" -}}
{{- include "dataproxy.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Pod labels: global pod labels + dataproxy labels + user-supplied dataproxy.podLabels.
*/}}
{{- define "dataproxy.podLabels" -}}
{{ include "global.podLabels" . }}
{{ include "dataproxy.labels" . }}
{{- with .Values.dataproxy.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
ServiceAccount name. Honors useCommonServiceAccount opt-out; otherwise
falls back to the chart default "dataproxy-system".
*/}}
{{- define "dataproxy.serviceAccountName" -}}
{{- if include "useCommonServiceAccount" . -}}
{{- include "common.serviceAccountName" . -}}
{{- else -}}
{{- default "dataproxy-system" .Values.dataproxy.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount annotations: global service account annotations + user-supplied.
*/}}
{{- define "dataproxy.serviceAccount.annotations" -}}
{{- include "global.serviceAccountAnnotations" . }}
{{- with .Values.dataproxy.serviceAccount.annotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "dataproxy.scheduling.topologySpreadConstraints" -}}
{{- with .Values.dataproxy.topologySpreadConstraints }}
topologySpreadConstraints:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "dataproxy.scheduling.affinity" -}}
{{- with .Values.dataproxy.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "dataproxy.scheduling.nodeSelector" -}}
{{- with .Values.dataproxy.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "dataproxy.scheduling.nodeName" -}}
{{- with .Values.dataproxy.nodeName }}
nodeName: {{ toYaml . }}
{{- end }}
{{- end }}

{{- define "dataproxy.scheduling.tolerations" -}}
{{- with .Values.dataproxy.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Aggregator: per-workload override falls back to global.scheduling.* when
the per-workload value is empty. Mirrors operator.scheduling /
leaseworker.scheduling / flytepropellerwebhook.scheduling /
clusterresourcesync.scheduling.
*/}}
{{- define "dataproxy.scheduling" -}}
{{- if .Values.dataproxy.topologySpreadConstraints }}
{{- include "dataproxy.scheduling.topologySpreadConstraints" . }}
{{- else }}
{{- include "global.scheduling.topologySpreadConstraints" . }}
{{- end }}
{{- if .Values.dataproxy.affinity }}
{{- include "dataproxy.scheduling.affinity" . }}
{{- else }}
{{- include "global.scheduling.affinity" . }}
{{- end }}
{{- if .Values.dataproxy.nodeSelector }}
{{- include "dataproxy.scheduling.nodeSelector" . }}
{{- else }}
{{- include "global.scheduling.nodeSelector" . }}
{{- end }}
{{- if .Values.dataproxy.nodeName }}
{{- include "dataproxy.scheduling.nodeName" . }}
{{- else }}
{{- include "global.scheduling.nodeName" . }}
{{- end }}
{{- if .Values.dataproxy.tolerations }}
{{- include "dataproxy.scheduling.tolerations" . }}
{{- else }}
{{- include "global.scheduling.tolerations" . }}
{{- end }}
{{- end -}}
