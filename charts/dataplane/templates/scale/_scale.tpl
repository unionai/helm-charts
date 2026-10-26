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
"true" when jobs are on: the chart sets the job task's image (scale.jobs.image.repository), and the
runtime turns jobs on whenever it has one.
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
{{- /* Without a caller key the operator proxy refuses every call but its agent's, so Scale's pages
       show it as not set up; a cluster whose key comes on a later sync still renders. The proxy
       NetworkPolicy keeps out pods outside the release namespace. Scale needs one of the two,
       whatever else is on. */}}
{{- if and (not .Values.scale.callerAuth.secretName) (not (include "scale.proxyNetworkPolicy.rendered" .)) }}
{{- fail "scale: Scale needs scale.callerAuth.secretName or scale.proxyNetworkPolicy.enabled, so a pod that reaches the operator proxy cannot read every project's issues" }}
{{- end }}
{{- /* Job pods run as the scale-job service account, which the cluster resource sync puts in
       every task namespace (templates/clusterresourcesync/configmap.yaml), or this chart in the
       release namespace when tasks run there. */}}
{{- if and (include "scale.jobs" .) (not (include "singleNamespace" .)) (not .Values.clusterresourcesync.enabled) }}
{{- fail "scale: jobs need clusterresourcesync.enabled, which gives every task namespace the scale-job service account and NetworkPolicy" }}
{{- end }}
{{- if and (include "scale.jobs" .) (not .Values.scale.jobs.networkPolicy.egress) }}
{{- fail "scale: jobs need scale.jobs.networkPolicy.egress, the places a job pod may reach" }}
{{- end }}
{{- if include "scale.writes" . }}
{{- /* Only AWS has a deny on Scale's bucket for every other identity and a role of its own for
       job pods. Elsewhere a later broad grant to a task identity would reach Scale's objects,
       so writes stay off unless the values say the deny in scale/README.md (Scale's bucket,
       step 4) is in place. */}}
{{- $cloud := include "scale.cloud" . }}
{{- if and (has $cloud (list "gcp" "azure")) (not .Values.scale.storageDenyConfigured) }}
{{- fail (printf "scale: fixes, pushes and jobs are not available on %s yet: Scale's bucket has no deny for other identities. Set the deny in scale/README.md (Scale's bucket) and scale.storageDenyConfigured, or leave them off" $cloud) }}
{{- end }}
{{- if not .Values.scale.auth.appId }}
{{- fail "scale: fixes, pushes and jobs need scale.auth.appId (the cluster's Scale app), not the operator's app" }}
{{- end }}
{{- if not .Values.scale.signing.secretName }}
{{- fail "scale: fixes, pushes and jobs need scale.signing.secretName, so a task pod cannot forge approvals" }}
{{- end }}
{{- if .Values.scale.signing.acceptUnsignedUntil }}
{{- fail "scale: fixes, pushes and jobs stay off while scale.signing.acceptUnsignedUntil keeps unsigned objects readable" }}
{{- end }}
{{- if not .Values.scale.callerAuth.secretName }}
{{- fail "scale: fixes, pushes and jobs need scale.callerAuth.secretName, so the operator proxy can check who the dataproxy says is calling" }}
{{- end }}
{{- if not .Values.scale.storageContainer }}
{{- fail "scale: fixes, pushes and jobs need scale.storageContainer, a bucket user task roles cannot reach" }}
{{- end }}
{{- if not .Values.scale.serviceAccount.create }}
{{- fail "scale: fixes, pushes and jobs need scale.serviceAccount.create, so Scale does not run as the operator" }}
{{- end }}
{{- $fix := dig "fix" dict $config }}
{{- $runtimeCredentials := dig "writer" "useRuntimeCredentials" false $fix }}
{{- /* The runtime refuses useRuntimeCredentials outside Union's own org (scale/config/fix.go), so
       the chart does not take it in place of the writer anywhere else. */}}
{{- if and $runtimeCredentials (ne (include "scale.org" .) "dogfood") }}
{{- fail "scale: scale.config.fix.writer.useRuntimeCredentials is for the dogfood org only; set scale.fixWriter.secretName" }}
{{- end }}
{{- if and (or (dig "enabled" false $fix) (include "scale.jobs" .)) (not .Values.scale.fixWriter.secretName) (not $runtimeCredentials) }}
{{- fail "scale: fixes and jobs need scale.fixWriter.secretName, the development-only writer app (provisionctl create scalefixwriter)" }}
{{- end }}
{{- if not (include "scale.proxyNetworkPolicy.rendered" .) }}
{{- fail "scale: fixes, pushes and jobs need scale.proxyNetworkPolicy.enabled, so pods outside the release namespace cannot reach the operator proxy" }}
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
The service account Scale's job pods run as (the job task's pod template names it), in one task
namespace. It holds the job identity from scale.jobs.serviceAccount.annotations, never the task
role, and mounts no token unless a pod asks; the job pod asks for none. Arguments: root, namespace
(a name, or "{{ namespace }}" for the cluster-resource templates).
*/}}
{{- define "scale.jobs.serviceAccount" -}}
{{- $root := .root -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scale-job
  namespace: {{ .namespace }}
  {{- with $root.Values.scale.jobs.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end -}}

{{/*
The NetworkPolicy on Scale's job pods (the label the job task's pod template sets) in one task
namespace: no ingress, and egress to DNS and scale.jobs.networkPolicy.egress only (by default
public addresses on 443: the model provider, the git host, object storage and the control plane;
never cluster or private addresses or the instance metadata service). Arguments as above.
*/}}
{{- define "scale.jobs.networkPolicy" -}}
{{- $np := .root.Values.scale.jobs.networkPolicy -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: scale-job
  namespace: {{ .namespace }}
spec:
  podSelector:
    matchLabels:
      union.ai/scale-job: "true"
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        {{- toYaml $np.dns | nindent 8 }}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    {{- toYaml $np.egress | nindent 4 }}
{{- end -}}
