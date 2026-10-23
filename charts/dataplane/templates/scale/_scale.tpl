{{/*
Scale: a per-project helper that watches runs in this dataplane, groups repeated failures and
waste into issues, and explains them in the Union console. It is off by default (scale.enabled).
Customer data stays in this dataplane: issues, feedback and the agent's memory live in this
cluster's bucket, and the control plane only relays requests to the operator proxy.

These templates mirror the union-operator chart in unionai/cloud
(operator/deploy/helm/templates/scale/*), including every guard; a change here is a change there.
*/}}

{{- define "scale.labels" -}}
{{ include "scale.selectorLabels" . }}
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "scale.selectorLabels" -}}
app: scale
{{- end -}}

{{- define "scale-agent.labels" -}}
app: scale-agent
platform.union.ai/service-group: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "scale.org" -}}
{{- tpl .Values.orgName . -}}
{{- end -}}

{{/*
Scale's agent's cluster-local address, through Knative's internal gateway.
*/}}
{{- define "scale-agent.url" -}}
http://scale-agent.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/*
"true" when the operator proxy gets a scale section: it reads Scale's bucket or checks
signatures, caller assertions or the agent's tokens.
*/}}
{{- define "scale.proxyConfig.enabled" -}}
{{- $s := .Values.scale -}}
{{- if and $s.enabled (or $s.signing.secretName $s.storageContainer $s.callerAuth.secretName $s.agent.enabled) -}}
true
{{- end -}}
{{- end -}}

{{/*
The operator proxy's scale section (proxy.scale in the operator ConfigMap). Must match the Scale
runtime's settings (templates/scale/configmap.yaml).
*/}}
{{- define "scale.proxyConfig" -}}
{{- $s := .Values.scale -}}
{{- with $s.signing.secretName }}
signingKeyPath: /etc/union/scale-signing/{{ $s.signing.key }}
{{- end }}
storageContainer: {{ $s.storageContainer | quote }}
{{- with $s.callerAuth.secretName }}
callerKeyPath: /etc/union/scale-caller/{{ $s.callerAuth.key }}
{{- end }}
{{- if $s.callerAuth.requireDigest }}
{{- /* Refuse caller assertions that do not bind the request body. */}}
requireDigest: true
{{- end }}
{{- /* Caller assertions must name this org and cluster. */}}
organization: {{ include "scale.org" . | quote }}
cluster: {{ include "getClusterName" . | quote }}
{{- if $s.agent.enabled }}
{{- /* Questions in the console go to Scale's agent in this cluster. */}}
agent:
  url: {{ include "scale-agent.url" . }}
  answerTimeout: {{ printf "%ds" ($s.agent.timeoutSeconds | int) }}
  awakeFor: {{ $s.agent.scaleDownDelay }}
  dailyQuestions: {{ $s.agent.dailyQuestions | int }}
  dailyDiagnoses: {{ $s.agent.dailyTrackedRuns | int }}
  {{- /* The agent's model and key as people save them in the console, read from this cluster's
         secret store; see templates/scale/_agent.tpl. */}}
  modelFromSecret: {{ include "scale.agent.modelFromConsole" . | eq "true" }}
{{- end }}
{{- end -}}

{{/*
The cloud Scale prices issues for (scale.config.detectors.cost.cloud): provider, else gcp for a
cluster that stores data in GCS. Empty when neither says, which the Scale runtime takes as the
usage price table's own cloud (AWS).
*/}}
{{- define "scale.cloud" -}}
{{- $provider := tpl (.Values.provider | default "" | toString) . -}}
{{- $storage := tpl (.Values.storage.provider | default "" | toString) . -}}
{{- if $provider -}}
{{- lower $provider -}}
{{- else if has $storage (list "gcs" "gcp") -}}
gcp
{{- end -}}
{{- end -}}

{{/*
The dataplane dataproxy's scale section (zero trust): it serves this cluster's Scale issues and
signs who the caller is for the operator proxy.
*/}}
{{- define "scale.dataproxyConfig" -}}
{{- $s := .Values.scale -}}
enabled: true
clusterName: {{ include "getClusterName" . | quote }}
{{- with $s.callerAuth.secretName }}
callerKeyPath: /etc/union/scale-caller/{{ $s.callerAuth.key }}
{{- end }}
organization: {{ include "scale.org" . | quote }}
cluster: {{ include "getClusterName" . | quote }}
{{- end -}}

{{/*
The Knative pods that may open connections to the agent: the activator (while it wakes), the
autoscaler (metrics) and the internal gateway, which is this chart's Envoy (app: gateway) on the
vendored path and Kourier's 3scale-kourier-gateway on the knative-operator path.
*/}}
{{- define "scale-agent.knativeApps" -}}
{{- $apps := .Values.scale.agent.networkPolicy.knativeApps -}}
{{- if not $apps -}}
{{- $gateway := ternary "gateway" "3scale-kourier-gateway" (eq (include "serving.useVendoredGateway" .) "true") -}}
{{- $apps = list "activator" "autoscaler" $gateway -}}
{{- end -}}
{{- toYaml $apps -}}
{{- end -}}

{{/*
"true" when Scale is set up to write: fixes or code pushes, turned on in either place the config
can say so (scale.config.fix.enabled, scale.git.enabled, scale.config.git.enabled). Every guard
that protects writes keys off this, so no setting can turn writes on around them.
*/}}
{{- define "scale.writes" -}}
{{- $config := .Values.scale.config | default dict -}}
{{- $git := .Values.scale.git | default dict -}}
{{- if or (dig "fix" "enabled" false $config) (dig "git" "enabled" false $config) (dig "enabled" false $git) -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when templates/scale/networkpolicy-proxy.yaml renders. The template and the guard both use
this, so the guard checks the policy that is actually rendered.
*/}}
{{- define "scale.proxyNetworkPolicy.rendered" -}}
{{- if and .Values.scale.enabled (dig "proxyNetworkPolicy" "enabled" false .Values.scale) -}}
true
{{- end -}}
{{- end -}}

{{/*
Fails the render when Scale's settings are unsafe or inconsistent. Fixes and pushes act on objects
other processes write and hold write credentials, so they need everything the security review asks
for (unionai/cloud scale/README.md, Security).
*/}}
{{- define "scale.guards" -}}
{{- if .Values.scale.enabled }}
{{- if not (include "scale.org" .) }}
{{- fail "scale: needs orgName (global.ORG_NAME): Scale's issues and the caller assertions the operator proxy checks name the organization" }}
{{- end }}
{{- /* The runtime's config loader matches keys case-insensitively, so Fix.Enabled would turn fixes
       on while every check below, which reads fix.enabled, saw nothing. Refuse any other spelling. */}}
{{- $config := .Values.scale.config | default dict }}
{{- range $k, $v := $config }}
{{- if and (has (lower $k) (list "fix" "git")) (ne $k (lower $k)) }}
{{- fail (printf "scale: write scale.config.%s as scale.config.%s; the guards only read lowercase" $k (lower $k)) }}
{{- end }}
{{- end }}
{{- range $section := list (dig "fix" dict $config) (dig "git" dict $config) (.Values.scale.git | default dict) }}
{{- range $k, $v := $section }}
{{- if and (eq (lower $k) "enabled") (ne $k "enabled") }}
{{- fail (printf "scale: write %s as enabled; the guards only read lowercase" $k) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.scale.signing.acceptUnsignedUntil (not .Values.scale.storageContainer) }}
{{- fail "scale: scale.signing.acceptUnsignedUntil needs scale.storageContainer; in the metadata bucket a task pod could plant unsigned objects during the window" }}
{{- end }}
{{- if hasKey $config "git" }}
{{- fail "scale: put code change settings under scale.git, not scale.config.git, so the GitHub App key is mounted and the guards apply" }}
{{- end }}
{{- if and .Values.scale.storageContainer (not .Values.storage.enableMultiContainer) }}
{{- fail "scale: scale.storageContainer needs storage.enableMultiContainer, or Scale cannot reach its bucket" }}
{{- end }}
{{- if include "scale.writes" . }}
{{- if not .Values.scale.auth.appId }}
{{- fail "scale: fixes and pushes need scale.auth.appId (the cluster's Scale app), not the operator's app" }}
{{- end }}
{{- if not .Values.scale.signing.secretName }}
{{- fail "scale: fixes and pushes need scale.signing.secretName, so a task pod cannot forge approvals" }}
{{- end }}
{{- if .Values.scale.signing.acceptUnsignedUntil }}
{{- fail "scale: fixes and pushes stay off while scale.signing.acceptUnsignedUntil keeps unsigned objects readable" }}
{{- end }}
{{- if not .Values.scale.callerAuth.secretName }}
{{- fail "scale: fixes and pushes need scale.callerAuth.secretName, so the operator proxy can check who the dataproxy says is calling" }}
{{- end }}
{{- if not .Values.scale.storageContainer }}
{{- fail "scale: fixes and pushes need scale.storageContainer, a bucket user task roles cannot reach" }}
{{- end }}
{{- if not .Values.scale.serviceAccount.create }}
{{- fail "scale: fixes and pushes need scale.serviceAccount.create, so Scale does not run as the operator" }}
{{- end }}
{{- $fix := dig "fix" dict $config }}
{{- if and (dig "enabled" false $fix) (not .Values.scale.fixWriter.secretName) (not (dig "writer" "useRuntimeCredentials" false $fix)) }}
{{- fail "scale: fixes need scale.fixWriter.secretName, the development-only writer app (provisionctl create scalefixwriter)" }}
{{- end }}
{{- if not (include "scale.proxyNetworkPolicy.rendered" .) }}
{{- fail "scale: fixes and pushes need scale.proxyNetworkPolicy.enabled, so pods outside the release namespace cannot reach the operator proxy" }}
{{- end }}
{{- end }}
{{- if .Values.scale.agent.enabled }}
{{- /* The agent writes back with tokens signed with Scale's key, and reads with the cluster's
       view-only Scale app, never the operator's. */}}
{{- if not .Values.scale.signing.secretName }}
{{- fail "scale.agent needs scale.signing.secretName: the operator proxy checks the agent's tokens with that key" }}
{{- end }}
{{- if not .Values.scale.auth.appId }}
{{- fail "scale.agent needs scale.auth.appId, the cluster's view-only Scale app; it never reads with the operator's app" }}
{{- end }}
{{- include "scale.agent.modelGuards" . }}
{{- if not (include "apps.enabled" .) }}
{{- fail "scale.agent runs as a Knative service and needs app serving: set apps.enabled" }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
