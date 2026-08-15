{{/*
Chart name (nameOverride wins).
*/}}
{{- define "dataplane-tools.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified release name (fullnameOverride wins).
*/}}
{{- define "dataplane-tools.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Namespace for rendered workloads (namespace override wins over release namespace).
*/}}
{{- define "dataplane-tools.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{/*
Helm-standard labels applied to every resource.
*/}}
{{- define "dataplane-tools.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: dataplane-tools
{{- end -}}

{{/*
Knative capability gates. The whole point of this chart is that a data plane may
or may not have Knative Serving installed (it arrives with the vendored gateway,
dataplane chart gateway.enabled=true) — so every Knative resource is gated on the
CRD's API actually being served rather than assumed to exist. On a cluster without
Knative these emit "" and callers render nothing.

Note: `helm template` without `--api-versions` reports these as absent, so snapshot
tests / manual renders must pass
`--api-versions serving.knative.dev/v1 --api-versions serving.knative.dev/v1beta1`
to exercise the Knative paths (mirrors how the repo tests monitoring.coreos.com/v1).
*/}}
{{- define "dataplane-tools.hasKnativeServing" -}}
{{- if .Capabilities.APIVersions.Has "serving.knative.dev/v1" -}}true{{- end -}}
{{- end -}}

{{- define "dataplane-tools.hasKnativeDomainMapping" -}}
{{- if .Capabilities.APIVersions.Has "serving.knative.dev/v1beta1" -}}true{{- end -}}
{{- end -}}
