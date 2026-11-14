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
  anthropicOnly: {{ include "scale.agent.anthropicOnly" . | eq "true" }}
  {{- /* "Keep Scale warm": minScale 1 or more wins over the console's setting; the requests
         price one running replica. */}}
  minScale: {{ $s.agent.minScale | default 0 | int }}
  {{- with ($s.agent.resources | default dict).requests }}
  requests:
    cpu: {{ .cpu | default "" | quote }}
    memory: {{ .memory | default "" | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
The cluster's cloud: what Scale prices issues for (scale.config.detectors.cost.cloud) and what the
write guard checks (scale.guards). provider, else the cloud of the cluster's storage: gcp for GCS,
custom stow storage of kind azure or google as the union-operator
chart reads it (operator/deploy/helm/templates/_helpers.tpl, scale.cloud), and a metadata prefix
on Azure Blob storage (abfs, abfss, azblob, wasb, wasbs) or GCS (gs). Empty when none says, which
the Scale runtime takes as the usage price table's own cloud (AWS).
*/}}
{{- define "scale.cloud" -}}
{{- $provider := lower (tpl (.Values.provider | default "" | toString) .) -}}
{{- $storage := tpl (.Values.storage.provider | default "" | toString) . -}}
{{- /* The stow keys in any case: the storage config's loader matches keys case-insensitively, so
       Kind: azure is Azure storage too. */ -}}
{{- $stow := dict -}}
{{- range $k, $v := (.Values.storage.custom | default dict) -}}
{{- if and (eq (lower $k) "stow") (kindIs "map" $v) }}{{ $stow = $v }}{{ end -}}
{{- end -}}
{{- $stowKind := "" -}}
{{- range $k, $v := $stow -}}
{{- if eq (lower $k) "kind" }}{{ $stowKind = lower (tpl (toString $v) $) }}{{ end -}}
{{- end -}}
{{- $scheme := lower (regexFind "^[A-Za-z0-9+.-]+://" (tpl (.Values.storage.metadataPrefix | default "" | toString) .)) | trimSuffix "://" -}}
{{- $fromStorage := "" -}}
{{- if has $storage (list "gcs" "gcp") -}}
{{- $fromStorage = "gcp" -}}
{{- else if and (eq $storage "custom") (eq $stowKind "azure") -}}
{{- $fromStorage = "azure" -}}
{{- else if and (eq $storage "custom") (eq $stowKind "google") -}}
{{- $fromStorage = "gcp" -}}
{{- else if has $scheme (list "abfs" "abfss" "azblob" "wasb" "wasbs") -}}
{{- $fromStorage = "azure" -}}
{{- else if eq $scheme "gs" -}}
{{- $fromStorage = "gcp" -}}
{{- end -}}
{{- /* provider wins over the storage settings, so a provider that names another cloud than the
       storage would price issues for the wrong cloud and skip the write guard on GCP and Azure. */ -}}
{{- if and $provider $fromStorage (ne $provider $fromStorage) -}}
{{- fail (printf "scale: provider is %s but the storage settings name %s: Scale prices issues and checks the bucket deny for one cloud. Correct provider or the storage settings" $provider $fromStorage) -}}
{{- end -}}
{{- $provider | default $fromStorage -}}
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
{{- /* The runtime deletes conversations past this; the proxy stops serving them at the same age. */}}
{{- $retention := dig "retention" dict ($s.config | default dict) }}
{{- if hasKey $retention "conversations" }}
conversationRetention: {{ $retention.conversations | toString | quote }}
{{- end }}
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
"true" when the values ask for jobs: the job task's image (scale.jobs.image.repository), which the
runtime turns jobs on with. Jobs are not available in this chart, so the guards fail the render
then (see scale.guards).
*/}}
{{- define "scale.jobs" -}}
{{- if dig "jobs" "image" "repository" "" (.Values.scale | default dict) -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" when Scale is set up to write: fixes, code pushes or jobs, turned on in any place the
config can say so (scale.config.fix.enabled, scale.git.enabled, scale.config.git.enabled,
scale.jobs.image.repository). Every guard that protects writes keys off this, so no setting can
turn writes on around them.
*/}}
{{- define "scale.writes" -}}
{{- $config := .Values.scale.config | default dict -}}
{{- $git := .Values.scale.git | default dict -}}
{{- if or (dig "fix" "enabled" false $config) (dig "git" "enabled" false $config) (dig "enabled" false $git) (include "scale.jobs" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
"true" on a serverless cluster, which runs tasks for many orgs. The serverless dataplane values mark
it in the cluster resource manager's config (clusterResourcesPrivate.app.isServerless).
*/}}
{{- define "scale.serverless" -}}
{{- $crm := dig "config" dict (.Values.clusterresourcesync | default dict) -}}
{{- if or (dig "clusterResourcesPrivate" "app" "isServerless" false $crm) (dig "cluster_resources" "isServerless" false $crm) -}}
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
{{- /* The caller key is per cluster. On a cluster shared by many orgs, the operator proxy could
       not tell one org's signed calls from another's key, so Scale stays off there until caller
       keys are per org. */}}
{{- if include "scale.serverless" . }}
{{- fail "scale: Scale cannot run on a serverless (multi-org) cluster yet: caller keys are per cluster, not per org. Leave scale.enabled off" }}
{{- end }}
{{- /* Tasks never share a namespace with Scale's signing, caller and model keys, Scale's app
       secrets and service account, or the operator proxy: a task pod can mount any Secret and
       name any service account of its own namespace, and every pod there passes a policy that
       admits the namespace. In single-namespace mode (singleNamespace, or its older name low_privilege,
       true or unset) tasks run in the release namespace, so Scale stays off; so does a namespace template that
       sends every task to the release namespace or to the proxy's secret store namespace, where
       the console saves the agent's model key. */}}
{{- if include "singleNamespace" . }}
{{- fail (printf "scale: Scale needs tasks in namespaces of their own (singleNamespace: false; low_privilege is its older name). In single-namespace mode tasks run in %s beside Scale's signing, caller and model keys and the operator proxy, and a task could read them. Leave scale.enabled off" .Release.Namespace) }}
{{- end }}
{{- /* Each placeholder ({{ project }}, {{ domain }}) stands for any project or domain name, so the
       template fails when some project or domain makes it the release namespace or the secret
       store namespace (project union, domain production gives union-production). An empty
       template is the operator's default, {{ project }}-{{ domain }}. */}}
{{- $taskNamespace := tpl (include "dataplane.namespaceTemplate" . | toString) . | trim }}
{{- $placeholder := "\\{\\{[^}]*\\}\\}" }}
{{- if not $taskNamespace }}
{{- $taskNamespace = "{{ project }}-{{ domain }}" }}
{{- end }}
{{- $literals := list }}
{{- range (regexSplit $placeholder $taskNamespace -1) }}
{{- $literals = append $literals (regexQuoteMeta .) }}
{{- end }}
{{- $pattern := printf "^%s$" (join "[a-z0-9-]+" $literals) }}
{{- range $ns := uniq (list .Release.Namespace (include "proxy.secretsNamespace" . | trim)) }}
{{- if regexMatch $pattern $ns }}
{{- if regexMatch $placeholder $taskNamespace }}
{{- fail (printf "scale: Scale needs tasks in namespaces of their own, but namespace_mapping.template %s puts a project's tasks in %s for some project or domain name, beside Scale's keys or the operator proxy's secret store. Use a template no project or domain can turn into %s (a fixed prefix such as tasks-{{ project }}-{{ domain }}), or leave scale.enabled off" $taskNamespace $ns $ns) }}
{{- end }}
{{- fail (printf "scale: Scale needs tasks in namespaces of their own, but namespace_mapping.template puts every task in %s, beside Scale's keys or the operator proxy's secret store. Use a template per project and domain, or leave scale.enabled off" $ns) }}
{{- end }}
{{- end }}
{{- /* The runtime's config loader matches keys case-insensitively, so Fix.Enabled would turn fixes
       on while every check below, which reads fix.enabled, saw nothing. Refuse any other spelling. */}}
{{- $config := .Values.scale.config | default dict }}
{{- range $k, $v := $config }}
{{- if and (has (lower $k) (list "fix" "git" "jobs" "agent")) (ne $k (lower $k)) }}
{{- fail (printf "scale: write scale.config.%s as scale.config.%s; the guards only read lowercase" $k (lower $k)) }}
{{- end }}
{{- end }}
{{- /* Jobs are not available in this chart. A job needs a cloud credential made for it alone, the
       jobs network check and Scale's model relay, which only the union-operator chart in
       unionai/cloud has. A shared job identity on a service account any task can name (the design
       the union-operator chart removed) would let a task read and change every project's jobs. The
       runtime turns jobs on whenever it has a job image, so scale.config.jobs, which would reach
       the runtime around these guards, is refused too. */}}
{{- if include "scale.jobs" . }}
{{- fail "scale: jobs are not available in this chart yet: each job needs its own cloud credential, the jobs network check and Scale's model relay, which only the union-operator chart (unionai/cloud) has. Leave scale.jobs.image.repository empty" }}
{{- end }}
{{- if hasKey $config "jobs" }}
{{- fail "scale: remove scale.config.jobs: jobs are not available in this chart yet, and the runtime would turn them on around the chart's guards" }}
{{- end }}
{{- /* The proxy NetworkPolicy admits named pods only. The chart's ingress routes to the proxy, so
       its controller must be admitted: the chart's own ingress-nginx is, by its name label in the
       release namespace; any other, or the chart's under another name or namespace, is listed in
       scale.proxyNetworkPolicy.from. */}}
{{- $nginx := index .Values "ingress-nginx" | default dict }}
{{- $nginxNamespace := tpl (toString ($nginx.namespaceOverride | default "")) . }}
{{- $nginxName := tpl (toString ($nginx.nameOverride | default "")) . }}
{{- $nginxAdmitted := and $nginx.enabled (has $nginxNamespace (list "" .Release.Namespace)) (has $nginxName (list "" "ingress-nginx")) }}
{{- if and (include "scale.proxyNetworkPolicy.rendered" .) .Values.ingress.enabled (not $nginxAdmitted) (not .Values.scale.proxyNetworkPolicy.from) }}
{{- fail "scale: the proxy NetworkPolicy admits named pods only, and ingress.enabled routes to the operator proxy: list the ingress controller in scale.proxyNetworkPolicy.from (e.g. its namespace), or turn on the chart's ingress-nginx without ingress-nginx.nameOverride or ingress-nginx.namespaceOverride" }}
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
{{- /* Without a caller key the operator proxy refuses every call but its agent's, so Scale's pages
       show it as not set up; a cluster whose key comes on a later sync still renders. The proxy
       NetworkPolicy admits only the proxy's own callers. Scale needs one of the two, whatever
       else is on. */}}
{{- if and (not .Values.scale.callerAuth.secretName) (not (include "scale.proxyNetworkPolicy.rendered" .)) }}
{{- fail "scale: Scale needs scale.callerAuth.secretName or scale.proxyNetworkPolicy.enabled, so a pod that reaches the operator proxy cannot read every project's issues" }}
{{- end }}
{{- if include "scale.writes" . }}
{{- /* Only AWS has a deny on Scale's bucket for every other identity and a role of its own for
       job pods. Elsewhere a later broad grant to a task identity would reach Scale's objects,
       so writes stay off unless the values say the deny in scale/README.md (Scale's bucket,
       step 4) is in place. */}}
{{- $cloud := include "scale.cloud" . }}
{{- if and (has $cloud (list "gcp" "azure")) (not .Values.scale.storageDenyConfigured) }}
{{- fail (printf "scale: fixes and pushes are not available on %s yet: Scale's bucket has no deny for other identities. Set the deny in scale/README.md (Scale's bucket) and scale.storageDenyConfigured, or leave them off" $cloud) }}
{{- end }}
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
{{- $runtimeCredentials := dig "writer" "useRuntimeCredentials" false $fix }}
{{- /* The runtime refuses useRuntimeCredentials outside Union's own org (scale/config/fix.go), so
       the chart does not take it in place of the writer anywhere else. */}}
{{- if and $runtimeCredentials (ne (include "scale.org" .) "dogfood") }}
{{- fail "scale: scale.config.fix.writer.useRuntimeCredentials is for the dogfood org only; set scale.fixWriter.secretName" }}
{{- end }}
{{- if and (dig "enabled" false $fix) (not .Values.scale.fixWriter.secretName) (not $runtimeCredentials) }}
{{- fail "scale: fixes need scale.fixWriter.secretName, the development-only writer app (provisionctl create scalefixwriter)" }}
{{- end }}
{{- if not (include "scale.proxyNetworkPolicy.rendered" .) }}
{{- fail "scale: fixes and pushes need scale.proxyNetworkPolicy.enabled, so only the operator proxy's own callers reach it" }}
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

{{/*
The pods of the chart's Prometheus, in the release namespace: the prometheus subchart's server and
kube-prometheus-stack's Prometheus (monitoring) both carry this label. The union-services job
scrapes the operator proxy's debug port.
*/}}
{{- define "scale.prometheusSelectorLabels" -}}
app.kubernetes.io/name: prometheus
{{- end -}}
