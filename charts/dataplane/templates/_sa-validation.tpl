{{/*
Validate that the default ServiceAccount can be managed by Helm.
If it exists without Helm ownership labels, fail with helpful instructions.
This only runs when clusterresourcesync is disabled and low_privilege is enabled.
*/}}
{{- define "validateDefaultServiceAccount" -}}
{{- $releaseName := .Release.Name -}}
{{- $releaseNamespace := .Release.Namespace -}}
{{- $sa := lookup "v1" "ServiceAccount" $releaseNamespace "default" -}}
{{- if $sa -}}
  {{- $managedBy := index ($sa.metadata.labels | default dict) "app.kubernetes.io/managed-by" -}}
  {{- $releaseAnnotation := index ($sa.metadata.annotations | default dict) "meta.helm.sh/release-name" -}}
  {{- if and $managedBy (ne $managedBy "Helm") -}}
    {{- fail (printf "\n\nERROR: The 'default' ServiceAccount in namespace '%s' exists but is managed by '%s', not Helm.\n\nTo allow Helm to manage it, run:\n\n  kubectl annotate serviceaccount default -n %s \\\n    meta.helm.sh/release-name=%s \\\n    meta.helm.sh/release-namespace=%s \\\n    --overwrite\n\n  kubectl label serviceaccount default -n %s \\\n    app.kubernetes.io/managed-by=Helm \\\n    --overwrite\n\nThen retry the installation.\n" $releaseNamespace $managedBy $releaseNamespace $releaseName $releaseNamespace $releaseNamespace) -}}
  {{- else if not $releaseAnnotation -}}
    {{- fail (printf "\n\nERROR: The 'default' ServiceAccount in namespace '%s' already exists but is not managed by Helm.\n\nTo allow Helm to manage it, run:\n\n  kubectl annotate serviceaccount default -n %s \\\n    meta.helm.sh/release-name=%s \\\n    meta.helm.sh/release-namespace=%s \\\n    --overwrite\n\n  kubectl label serviceaccount default -n %s \\\n    app.kubernetes.io/managed-by=Helm \\\n    --overwrite\n\nThen retry the installation.\n" $releaseNamespace $releaseNamespace $releaseName $releaseNamespace $releaseNamespace) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
