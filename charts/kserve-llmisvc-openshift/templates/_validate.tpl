{{/*
Render-time guards. Each of these is a mistake that produces a healthy-looking
install and a broken one at first use, so it is cheaper to fail the render.
*/}}
{{- define "kserve-llmisvc-openshift.validate" -}}
{{- $sub := index .Values "kserve-llmisvc-resources" -}}

{{/* 1. The CRD hardcodes the controller's namespace. */}}
{{- with .Values.openshift.enforceNamespace }}
{{- if ne $.Release.Namespace . }}
{{- fail (printf "this chart must be installed in namespace %q, not %q: the llminferenceservices CRD hardcodes its conversion-webhook service and cert-manager CA injection to that namespace and the upstream CRD chart does not template it. Override openshift.enforceNamespace only if that has changed upstream." . $.Release.Namespace) }}
{{- end }}
{{- end }}

{{/* 2. kserveGateway must be <namespace>/<name>; a bare name silently
      resolves to the release namespace and the HTTPRoutes never attach. */}}
{{- $gw := $sub.kserve.controller.gateway.ingressGateway.kserveGateway | default "" }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $gw) }}
{{- fail (printf "kserve.controller.gateway.ingressGateway.kserveGateway must be \"<namespace>/<name>\", got %q" $gw) }}
{{- end }}

{{/* 3. Leaving createGIECRDs on puts four cluster-scoped CRDs in templates/,
      which `helm uninstall` then deletes cluster-wide. */}}
{{- if $sub.kserve.llmisvc.createGIECRDs }}
{{- fail "kserve.llmisvc.createGIECRDs must stay false: it renders inferencepools/inferenceobjectives/inferencemodelrewrites CRDs into templates/, so `helm uninstall` would delete them and every custom resource of those kinds on the cluster. hack/install-crds.sh applies them out of band." }}
{{- end }}
{{- end -}}
