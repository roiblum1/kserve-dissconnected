{{/*
Render-time guards for the things that would damage a shared cluster.
*/}}
{{- define "envoy-gateway-openshift.validate" -}}
{{- $eg := index .Values "envoy-gateway" -}}

{{/* crds.enabled is a subchart CONDITION, so false skips the whole crds
     subchart -- its crds/ directory AND its templates/. This is the primary
     guard; check it first so the error names the root cause. Note gateway-helm
     v1.8.1 has no such key, which is why this chart requires v1.9.1. */}}
{{- if dig "crds" "enabled" false $eg }}
{{- fail "envoy-gateway.crds.enabled must be false: the crds subchart ships experimental-channel Gateway API CRDs that would overwrite the cluster-ingress-operator's. hack/install-crds.sh installs the gateway.envoyproxy.io group out of band." }}
{{- end }}

{{/* The safe-upgrade ValidatingAdmissionPolicy intercepts every CRD write on
     the cluster (apiextensions.k8s.io/v1, resources: ["*"], failurePolicy:
     Fail) and denies Gateway API CRDs with bundle-version ^v1\.[0-4]. On
     OpenShift that is the ingress-operator's own reconcile writes. */}}
{{- if dig "crds" "gatewayAPI" "safeUpgradePolicy" "enabled" false $eg }}
{{- fail "envoy-gateway.crds.gatewayAPI.safeUpgradePolicy.enabled must be false: it installs the cluster-scoped safe-upgrades.gateway.networking.k8s.io ValidatingAdmissionPolicy, which matches every CustomResourceDefinition write with failurePolicy: Fail and denies Gateway API CRDs whose bundle-version is v1.0-v1.4. On OpenShift the cluster-ingress-operator owns those CRDs, so this would reject its reconcile writes cluster-wide, for every tenant." }}
{{- end }}

{{/* The extension hook must point somewhere, or Gateways never finish
     programming and the failure looks like a data-plane problem. */}}
{{- with dig "config" "envoyGateway" "extensionManager" nil $eg }}
{{- if not (dig "service" "fqdn" "hostname" "" .) }}
{{- fail "envoy-gateway.config.envoyGateway.extensionManager is set but service.fqdn.hostname is empty; Gateways would stay PROGRAMMED=False" }}
{{- end }}
{{- end }}
{{- end -}}
