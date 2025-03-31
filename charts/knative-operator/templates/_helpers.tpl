{{/*
Allow the user to specify the namespace to install components to.  This allows us
to install knative-operator in its own namespace, while still allowing other charts
(ie: dataplane) to depend on it, and avoid installing in the Helm release namespace.
*/}}
{{- define "knative-operator.namespace "-}}
{{- default "knative-operator" .Values.namespaceOverride | quote -}}
{{- end -}}
