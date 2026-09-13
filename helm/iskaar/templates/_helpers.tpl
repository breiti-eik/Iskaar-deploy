{{- define "iskaar.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "iskaar.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "iskaar.imageReference" -}}
{{- $registry := .registry | default "" | trimSuffix "/" -}}
{{- if $registry -}}
{{ printf "%s/%s:%s" $registry .name .tag }}
{{- else -}}
{{ printf "%s:%s" .name .tag }}
{{- end -}}
{{- end -}}

{{- define "iskaar.postgresqlSecretName" -}}
{{- if .Values.postgresql.existingSecret -}}
{{- .Values.postgresql.existingSecret -}}
{{- else if .Values.postgresql.createPlaceholderSecret -}}
postgres-credentials
{{- else -}}
{{- fail "postgresql.existingSecret must be set when postgresql.createPlaceholderSecret is false" -}}
{{- end -}}

{{- end -}}