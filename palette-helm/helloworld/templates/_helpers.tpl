{{/* Fully-qualified app name: release name unless the user overrode it. */}}
{{- define "helloworld.fullname" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels applied to every object. */}}
{{- define "helloworld.labels" -}}
app.kubernetes.io/name: helloworld
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* Selector labels — stable subset used by Service/Deployment selectors. */}}
{{- define "helloworld.selectorLabels" -}}
app.kubernetes.io/name: helloworld
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
