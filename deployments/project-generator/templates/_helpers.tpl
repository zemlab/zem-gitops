{{- define "project-generator.validate" -}}
{{- if not .Values.cluster -}}{{- fail "ERROR: '.Values.cluster' is required (e.g. cluster: cluster04)" -}}{{- end -}}
{{- end -}}
