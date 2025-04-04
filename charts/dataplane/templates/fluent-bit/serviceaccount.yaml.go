{{- if .Values.fluentbit.enabled -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "fluentbit.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "fluentbit.serviceAccountLabels" . | nindent 4 }}
  {{- with include "global.serviceAccountAnnotations" . }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
    eks.amazonaws.com/role-arn: arn:aws:iam::879381277806:role/troy-fluentbit
{{- end }}
