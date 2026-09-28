{{- define "envoy-ai-gateway-openshift.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envoy-ai-gateway-openshift.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "envoy-ai-gateway-openshift.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "envoy-ai-gateway-openshift.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: envoy-ai-gateway
{{- end -}}

{{/*
Annotations for a resource this chart adds: the caller's own annotations merged
with an Argo CD sync wave, emitted only if there is something to emit.

  {{- include "envoy-ai-gateway-openshift.annotations"
        (dict "wave" .Values.argocd.syncWave.gateway "extra" .Values.gateway.route.annotations) }}
*/}}
{{- define "envoy-ai-gateway-openshift.annotations" -}}
{{- $ann := dict -}}
{{- with .extra }}{{- $ann = merge $ann . }}{{- end -}}
{{- with .wave }}{{- $ann = merge $ann (dict "argocd.argoproj.io/sync-wave" (toString .)) }}{{- end -}}
{{- if $ann -}}
annotations:
  {{- toYaml $ann | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Namespace that holds the Gateway object. Defaults to the release namespace.
*/}}
{{- define "envoy-ai-gateway-openshift.gatewayNamespace" -}}
{{- default .Release.Namespace .Values.gateway.namespace -}}
{{- end -}}
