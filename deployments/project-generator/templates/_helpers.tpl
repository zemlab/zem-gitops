{{- define "project-generator.validate" -}}
{{- if not .Values.cluster.name -}}{{- fail "ERROR: '.Values.cluster.name' is required (e.g. cluster.name: cluster04)" -}}{{- end -}}
{{- end -}}
