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
{{- if and .Values.rateLimit.enabled (not .Values.rateLimit.redis.url) (not .Values.rateLimit.redis.existingSecret) -}}
{{- fail "rateLimit.enabled needs rateLimit.redis.url (host:port) or rateLimit.redis.existingSecret: quotas are counted in Redis" -}}
{{- end -}}
{{- if .Values.gateway.peers.enabled -}}
{{- if not .Values.gateway.site -}}
{{- fail "gateway.peers.enabled needs gateway.site: this cluster's name as registered in aigw-ui" -}}
{{- end -}}
{{- if not .Values.gateway.peers.serverName -}}
{{- fail "gateway.peers.enabled needs gateway.peers.serverName, for example peers.llm.<domain>" -}}
{{- end -}}
{{- if not (has .Values.gateway.peers.issuer.kind (list "ClusterIssuer" "Issuer")) -}}
{{- fail "gateway.peers.issuer.kind must be ClusterIssuer or Issuer" -}}
{{- end -}}
{{- end -}}
{{- end -}}
