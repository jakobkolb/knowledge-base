{{- define "knowledge-base.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Construct <subdomain>.<baseDomain>  (baseDomain already contains the "mcp" segment)
Usage: {{ include "knowledge-base.mcpHost" (dict "sub" "obsidian" "Values" .Values) }}
*/}}
{{- define "knowledge-base.mcpHost" -}}
{{- printf "%s.%s" .sub .Values.global.baseDomain -}}
{{- end -}}

{{/*
Auth server host: auth.<baseDomain>  (baseDomain already contains the "mcp" segment)
*/}}
{{- define "knowledge-base.authHost" -}}
{{- printf "auth.%s" .Values.global.baseDomain -}}
{{- end -}}
