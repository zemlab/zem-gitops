{{- define "project-instance.validate" -}}
{{- if not .Values.name -}}{{- fail "ERROR: '.Values.name' is required (the project name)" -}}{{- end -}}
{{- if not .Values.env -}}{{- fail "ERROR: '.Values.env' is required (the environment name)" -}}{{- end -}}
{{- end -}}

{{- define "project-instance.fullName" -}}
{{- printf "%s-%s" .Values.name .Values.env | trunc 63 | trimSuffix "-" }}
{{- end }}
