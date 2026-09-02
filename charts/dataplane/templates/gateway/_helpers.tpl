{{/*
serving.useVendoredGateway reports (as "true"/"") whether the vendored Knative
Serving control plane (activator, autoscaler, controller, webhook,
net-kourier-controller and their configs) should render — i.e. app serving is on
AND delivered by this chart's gateway rather than the knative-operator subchart.
Default delivery: gateway.enabled defaults true, so `apps.enabled` alone flips
serving to the vendored path. Emits "" when false so callers gate with
`{{- if include ... }}` (the string "false" is truthy in Helm).
*/}}
{{- define "serving.useVendoredGateway" -}}
{{- if and (include "apps.enabled" .) .Values.gateway.enabled -}}true{{- end -}}
{{- end }}

{{/*
serving.renderGateway reports whether the Envoy gateway plumbing (the Envoy
Deployment/Service + its bootstrap ConfigMap) should render. The Envoy gateway
fronts app serving (vendored path) AND, under zero trust, the dataproxy static
routes — so it is needed for either. gateway.enabled gates both.
*/}}
{{- define "serving.renderGateway" -}}
{{- if and .Values.gateway.enabled (or (include "apps.enabled" .) .Values.zero_trust.enabled) -}}true{{- end -}}
{{- end }}

{{/*
serving.useKnativeOperator reports whether the legacy knative-operator
KnativeServing-CR path should render (app serving on, gateway.enabled false).
*/}}
{{- define "serving.useKnativeOperator" -}}
{{- if and (include "apps.enabled" .) (not .Values.gateway.enabled) -}}true{{- end -}}
{{- end }}

{{/*
serving.validateGateway fails the render for unsupported combinations. Zero trust
layers its dataproxy + dataplane-ingress routes on the Envoy gateway, so it
requires gateway.enabled (it cannot run on the knative-operator path).
*/}}
{{- define "serving.validateGateway" -}}
{{- if and .Values.zero_trust.enabled (not .Values.gateway.enabled) -}}
{{- fail "zero_trust.enabled requires the vendored gateway: set gateway.enabled=true (knative-operator delivery is not supported with zero trust)" -}}
{{- end -}}
{{- end }}

{{/*
Fully qualified gateway resource name.
Follows the parent chart convention: {union-operator.fullname}-gateway.
*/}}
{{- define "gateway.fullname" -}}
{{- printf "%s-gateway" (include "union-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Helm-standard labels applied to all gateway resources.
*/}}
{{- define "gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Upstream Knative identity labels.
Applied to all knative-serving resources.
*/}}
{{- define "gateway.knativeLabels" -}}
app.kubernetes.io/name: knative-serving
app.kubernetes.io/version: "1.16.0"
{{- end }}

{{/*
Tenant hostname and organization helpers used in the gateway path.

host is consumed unconditionally by the bootstrap configmap (listener
domain and CORS allow_origin), so it is required whenever zero_trust is
enabled.

organization is consumed only by the Envoy auth fallback path
(gateway.auth.enable=true with no gateway.auth.organization override),
so it is required only in that configuration. Emitting empty values for
either silently produces broken URLs like `https://` or `<cluster>.dp.`.
*/}}
{{- define "gateway.host" -}}
{{- include "dataplane.cp.host" . -}}
{{- end }}

{{- define "gateway.organization" -}}
{{- required "orgName is required when gateway.auth.enable is true and gateway.auth.organization is unset" (tpl .Values.orgName .) -}}
{{- end }}

{{/*
gateway.auth.insecureSkipVerify reports (as "true"/"") whether the Envoy auth
plugin should skip verification of the control-plane TLS certificate when it
dials the CP at startup. The gateway reaches the same control plane as the
operator (gateway.host == the operator's connection host); self-hosted control
planes serve a self-signed intracluster cert there, so the gateway must share
the operator's trust posture or the union-authn plugin panics at init with
x509: certificate signed by unknown authority.

Precedence: an explicit gateway.auth.insecureSkipVerify (bool) wins; otherwise
inherit config.union.connection.insecureSkipVerify (what leaseworker and the
operator use to reach the same host). Emits "" when false so callers gate with
`{{- if include ... }}`.
*/}}
{{- define "gateway.auth.insecureSkipVerify" -}}
{{- $g := .Values.gateway.auth.insecureSkipVerify -}}
{{- if not (kindIs "invalid" $g) -}}
{{- if $g -}}true{{- end -}}
{{- else if dig "union" "connection" "insecureSkipVerify" false .Values.config -}}
true
{{- end -}}
{{- end }}

{{/*
Collector: aggregates all backend envoy routes.
To add a new backend, add a conditional include block here.
NOTE: dataproxy.envoyRoute is a catch-all (prefix "/") and must remain last.
Place more specific routes above it or they will be shadowed.
*/}}
{{- define "gateway.extraRoutes" -}}
{{- if .Values.zero_trust.enabled }}
{{- include "dataproxy.envoyHttpRoute" . }}
{{- include "dataproxy.envoyRoute" . }}
{{- end }}
{{- end -}}

{{/*
Collector: aggregates all backend envoy clusters.
To add a new backend, add a conditional include block here.
*/}}
{{- define "gateway.extraClusters" -}}
{{- if .Values.zero_trust.enabled }}
{{- include "dataproxy.envoyCluster" . }}
{{- include "dataproxy.envoyHttpCluster" . }}
{{- end }}
{{- end -}}
