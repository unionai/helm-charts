{{/*
Unified secrets helpers.

Each managed secret follows the same shape under `.Values.secrets.<name>`:

  enabled: bool
  existingSecret:
    name: ""
    key: ""            # single-key secrets only — defaults to the canonical key
  value: ""            # inline value for single-key secrets
  # (multi-key secrets carry their inline fields at the top level — see eagerClientCreds, admin)

State machine (single- and multi-key alike):

  enabled: false                                  → render nothing; consumers must not reference
  enabled: true  + existingSecret.name set        → skip chart-managed Secret; consumers reference external by name
  enabled: true  + inline value(s) set            → chart creates `{{ .Release.Name }}-<logical>`; consumers reference it
  enabled: true  + existingSecret.name + inline   → fail (ambiguous)
  enabled: true  + neither                        → fail (must provide one)

Consumer pattern for single-key:

  {{- $ref := include "secrets.eagerApiKey.secretRef" . | fromYaml }}
  - name: EAGER_API_KEY
    valueFrom:
      secretKeyRef:
        name: {{ $ref.name }}
        key:  {{ $ref.key }}

Consumer pattern for multi-key (eagerClientCreds, admin):

  {{- $name := include "secrets.eagerClientCreds.secretName" . }}
  - name: UNION_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: {{ $name }}
        key:  {{ include "secrets.eagerClientCreds.clientIdKey" . }}
*/}}

{{/*
secrets.admin — admin client credentials.

Carries the unified shape but also accepts the legacy `enable` and `create` flags so
existing values files keep working. Default computed name is `union-secret-auth` to
preserve the name historically baked into consumer configs.

Legacy:
  enable: bool            (alias for enabled)
  create: bool            (legacy: false → external secret with hardcoded name `union-secret-auth`)
*/}}

{{- define "secrets.admin.computedName" -}}union-secret-auth{{- end -}}

{{- define "secrets.admin.enabled" -}}
{{- $s := .Values.secrets.admin -}}
{{- if hasKey $s "enabled" -}}{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- else if hasKey $s "enable" -}}{{- if $s.enable -}}true{{- else -}}false{{- end -}}
{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.admin.shouldCreate" -}}
{{- $s := .Values.secrets.admin -}}
{{- if eq (include "secrets.admin.enabled" .) "true" -}}
  {{- if $s.existingSecret.name -}}false
  {{- else if and (hasKey $s "create") (not $s.create) -}}false
  {{- else -}}true{{- end -}}
{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.admin.secretName" -}}
{{- $s := .Values.secrets.admin -}}
{{- if $s.existingSecret.name -}}{{ $s.existingSecret.name }}{{- else -}}{{ include "secrets.admin.computedName" . }}{{- end -}}
{{- end -}}

{{/*
secrets.eagerApiKey
*/}}

{{- define "secrets.eagerApiKey.canonicalKey" -}}EAGER_API_KEY{{- end -}}

{{- define "secrets.eagerApiKey.computedName" -}}{{ .Release.Name }}-eager-api-key{{- end -}}

{{- define "secrets.eagerApiKey.enabled" -}}
{{- $s := .Values.secrets.eagerApiKey -}}
{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.eagerApiKey.validate" -}}
{{- $s := .Values.secrets.eagerApiKey -}}
{{- if $s.enabled -}}
  {{- $hasExternal := $s.existingSecret.name -}}
  {{- $hasInline := $s.value -}}
  {{- if and $hasExternal $hasInline -}}
    {{- fail "secrets.eagerApiKey: set either existingSecret.name OR value, not both" -}}
  {{- end -}}
  {{- if not (or $hasExternal $hasInline) -}}
    {{- fail "secrets.eagerApiKey.enabled=true requires existingSecret.name or value" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets.eagerApiKey.secretRef" -}}
{{- include "secrets.eagerApiKey.validate" . -}}
{{- $s := .Values.secrets.eagerApiKey -}}
{{- $defaultKey := include "secrets.eagerApiKey.canonicalKey" . -}}
{{- if $s.existingSecret.name -}}
name: {{ $s.existingSecret.name }}
key: {{ default $defaultKey $s.existingSecret.key }}
{{- else -}}
name: {{ include "secrets.eagerApiKey.computedName" . }}
key: {{ $defaultKey }}
{{- end -}}
{{- end -}}

{{/*
secrets.eagerClientCreds — multi-key (client_id + client_secret)
*/}}

{{- define "secrets.eagerClientCreds.clientIdCanonical" -}}client_id{{- end -}}
{{- define "secrets.eagerClientCreds.clientSecretCanonical" -}}client_secret{{- end -}}

{{- define "secrets.eagerClientCreds.computedName" -}}{{ .Release.Name }}-eager-client-creds{{- end -}}

{{- define "secrets.eagerClientCreds.enabled" -}}
{{- $s := .Values.secrets.eagerClientCreds -}}
{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.eagerClientCreds.validate" -}}
{{- $s := .Values.secrets.eagerClientCreds -}}
{{- if $s.enabled -}}
  {{- $hasExternal := $s.existingSecret.name -}}
  {{- if and $hasExternal $s.clientSecret -}}
    {{- fail "secrets.eagerClientCreds: set either existingSecret.name OR an inline clientSecret, not both" -}}
  {{- end -}}
  {{- if not (or $hasExternal $s.clientSecret) -}}
    {{- fail "secrets.eagerClientCreds.enabled=true requires existingSecret.name or an inline clientSecret" -}}
  {{- end -}}
  {{- if and $s.clientSecret (not $s.clientId) -}}
    {{- fail "secrets.eagerClientCreds: clientId must be set alongside an inline clientSecret" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets.eagerOAuthConfig.configMapName" -}}{{ .Release.Name }}-eager-oauth-config{{- end -}}

{{- define "secrets.eagerClientCreds.secretName" -}}
{{- include "secrets.eagerClientCreds.validate" . -}}
{{- $s := .Values.secrets.eagerClientCreds -}}
{{- if $s.existingSecret.name -}}{{ $s.existingSecret.name }}{{- else -}}{{ include "secrets.eagerClientCreds.computedName" . }}{{- end -}}
{{- end -}}

{{- define "secrets.eagerClientCreds.clientIdKey" -}}
{{- $s := .Values.secrets.eagerClientCreds -}}
{{- default (include "secrets.eagerClientCreds.clientIdCanonical" .) $s.existingSecret.clientIdKey -}}
{{- end -}}

{{- define "secrets.eagerClientCreds.clientSecretKey" -}}
{{- $s := .Values.secrets.eagerClientCreds -}}
{{- default (include "secrets.eagerClientCreds.clientSecretCanonical" .) $s.existingSecret.clientSecretKey -}}
{{- end -}}

{{/*
secrets.internalCaCert — single-key (ca.crt) trust bundle for the CP
internal-tls cert. Cluster operators typically wire `existingSecret.name`
to an ExternalSecret-managed Secret (`internal-ca-bundle`); chart users
without ExternalSecrets supply the PEM inline via `value`.
*/}}

{{- define "secrets.internalCaCert.caCertCanonical" -}}ca.crt{{- end -}}

{{- define "secrets.internalCaCert.computedName" -}}{{ .Release.Name }}-internal-ca{{- end -}}

{{- define "secrets.internalCaCert.enabled" -}}
{{- $s := .Values.secrets.internalCaCert -}}
{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.internalCaCert.validate" -}}
{{- $s := .Values.secrets.internalCaCert -}}
{{- if $s.enabled -}}
  {{- $hasExternal := $s.existingSecret.name -}}
  {{- $hasInline := $s.value -}}
  {{- if and $hasExternal $hasInline -}}
    {{- fail "secrets.internalCaCert: set either existingSecret.name OR value, not both" -}}
  {{- end -}}
  {{- if not (or $hasExternal $hasInline) -}}
    {{- fail "secrets.internalCaCert.enabled=true requires existingSecret.name or value" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets.internalCaCert.secretName" -}}
{{- include "secrets.internalCaCert.validate" . -}}
{{- $s := .Values.secrets.internalCaCert -}}
{{- if $s.existingSecret.name -}}{{ $s.existingSecret.name }}{{- else -}}{{ include "secrets.internalCaCert.computedName" . }}{{- end -}}
{{- end -}}

{{- define "secrets.internalCaCert.caCertKey" -}}
{{- $s := .Values.secrets.internalCaCert -}}
{{- default (include "secrets.internalCaCert.caCertCanonical" .) $s.existingSecret.caCertKey -}}
{{- end -}}

{{/*
secrets.imageBuilder.push — buildkit push credentials (opaque KV)
*/}}

{{- define "secrets.imageBuilder.push.computedName" -}}{{ .Release.Name }}-image-builder-push{{- end -}}

{{- define "secrets.imageBuilder.push.enabled" -}}
{{- $s := .Values.secrets.imageBuilder.push -}}
{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.imageBuilder.push.validate" -}}
{{- $s := .Values.secrets.imageBuilder.push -}}
{{- if $s.enabled -}}
  {{- $hasExternal := $s.existingSecret.name -}}
  {{- $hasInline := gt (len $s.values) 0 -}}
  {{- if and $hasExternal $hasInline -}}
    {{- fail "secrets.imageBuilder.push: set either existingSecret.name OR values, not both" -}}
  {{- end -}}
  {{- if not (or $hasExternal $hasInline) -}}
    {{- fail "secrets.imageBuilder.push.enabled=true requires existingSecret.name or values" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets.imageBuilder.push.secretName" -}}
{{- include "secrets.imageBuilder.push.validate" . -}}
{{- $s := .Values.secrets.imageBuilder.push -}}
{{- if $s.existingSecret.name -}}{{ $s.existingSecret.name }}{{- else -}}{{ include "secrets.imageBuilder.push.computedName" . }}{{- end -}}
{{- end -}}

{{/*
secrets.imageBuilder.pull — image pull (imagePullSecrets dockerconfigjson). Absorbs depot-token.
*/}}

{{- define "secrets.imageBuilder.pull.canonicalKey" -}}.dockerconfigjson{{- end -}}

{{- define "secrets.imageBuilder.pull.computedName" -}}{{ .Release.Name }}-image-builder-pull{{- end -}}

{{- define "secrets.imageBuilder.pull.enabled" -}}
{{- $s := .Values.secrets.imageBuilder.pull -}}
{{- if $s.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "secrets.imageBuilder.pull.validate" -}}
{{- $s := .Values.secrets.imageBuilder.pull -}}
{{- if $s.enabled -}}
  {{- $hasExternal := $s.existingSecret.name -}}
  {{- $hasInline := $s.dockerconfigjson -}}
  {{- if and $hasExternal $hasInline -}}
    {{- fail "secrets.imageBuilder.pull: set either existingSecret.name OR dockerconfigjson, not both" -}}
  {{- end -}}
  {{- if not (or $hasExternal $hasInline) -}}
    {{- fail "secrets.imageBuilder.pull.enabled=true requires existingSecret.name or dockerconfigjson" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "secrets.imageBuilder.pull.secretName" -}}
{{- include "secrets.imageBuilder.pull.validate" . -}}
{{- $s := .Values.secrets.imageBuilder.pull -}}
{{- if $s.existingSecret.name -}}{{ $s.existingSecret.name }}{{- else -}}{{ include "secrets.imageBuilder.pull.computedName" . }}{{- end -}}
{{- end -}}

{{/*
Common labels for chart-managed Secrets + ConfigMaps that the operator
mirrors into task namespaces. app.kubernetes.io/managed-by is load-bearing
— the ManifestMirrorSyncer (and the controller-side MirrorChecker cache)
select mirror sources on it, so it always derives from
mirroring.managedByLabelValue and is not user-overridable. secrets.commonLabels
is appended for arbitrary user metadata.
*/}}
{{- define "secrets.managedObjectLabels" -}}
app.kubernetes.io/managed-by: {{ .Values.mirroring.managedByLabelValue | default "union-operator" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Values.secrets.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Eager OAuth file-mount paths. The same values feed both the SDK config.yaml
(clientSecretLocation / caCertFilePath) and the controller's podInject volume
mounts, so they stay consistent. Overridable via mirroring.eagerOAuth.
*/}}
{{- define "secrets.eagerOAuth.configMapMountPath" -}}
{{- dig "eagerOAuth" "configMapMountPath" "/etc/flyte/config.yaml" .Values.mirroring -}}
{{- end -}}
{{- define "secrets.eagerOAuth.secretMountPath" -}}
{{- dig "eagerOAuth" "secretMountPath" "/etc/flyte/credentials/client_secret" .Values.mirroring -}}
{{- end -}}
{{- define "secrets.eagerOAuth.caCertMountPath" -}}
{{- dig "eagerOAuth" "caCertMountPath" "/etc/flyte/credentials/ca.crt" .Values.mirroring -}}
{{- end -}}
