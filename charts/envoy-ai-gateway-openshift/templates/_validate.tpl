{{/*
`gateway.envoyGatewayNamespace` (used by this chart's Service and Route) and
`ai-gateway.envoyGateway.namespace` (passed to the upstream controller) must
name the same namespace. If they drift, the Route silently points at a Service
with no endpoints, which is tedious to debug. Fail the render instead.
*/}}
{{- define "envoy-ai-gateway-openshift.validate" -}}
{{- $sub := index .Values "ai-gateway" -}}
{{- $subNs := "" -}}
{{- if $sub -}}
{{- if $sub.envoyGateway -}}
{{- $subNs = $sub.envoyGateway.namespace -}}
{{- end -}}
{{- end -}}
{{- if and $subNs (ne $subNs .Values.gateway.envoyGatewayNamespace) -}}
{{- fail (printf "namespace mismatch: gateway.envoyGatewayNamespace=%q but ai-gateway.envoyGateway.namespace=%q; both must point at the namespace where Envoy Gateway runs" .Values.gateway.envoyGatewayNamespace $subNs) -}}
{{- end -}}
{{- end -}}
