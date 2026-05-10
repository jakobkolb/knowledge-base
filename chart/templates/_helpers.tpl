{{- define "knowledge-base.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Construct <subdomain>.mcp.<baseDomain>
Usage: {{ include "knowledge-base.mcpHost" (dict "sub" "obsidian" "Values" .Values) }}
*/}}
{{- define "knowledge-base.mcpHost" -}}
{{- printf "%s.mcp.%s" .sub .Values.global.baseDomain -}}
{{- end -}}

{{/*
Auth server host: auth.mcp.<baseDomain>
*/}}
{{- define "knowledge-base.authHost" -}}
{{- printf "auth.mcp.%s" .Values.global.baseDomain -}}
{{- end -}}
