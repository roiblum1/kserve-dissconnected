#!/usr/bin/env bash
#
# PLAIN-HELM PATH ONLY. Under Argo CD you do not need this: every CRD ships in
# its chart's crds/ and the Application applies it at sync wave -10.
#
# Applies the CRDs this stack owns, exactly as committed in the charts:
#   envoy-gateway  charts/envoy-gateway-openshift/crds/     gateway.envoyproxy.io,
#                                                           inference.networking.(x-)k8s.io
#   ai-gateway     charts/envoy-ai-gateway-openshift/crds/  aigateway.envoyproxy.io
#   kserve         charts/kserve-llmisvc-openshift/crds/    serving.kserve.io, llm-d.ai
#   lws            the vendored lws subchart's own crds/    leaderworkerset.x-k8s.io,
#                                                           disaggregatedset.x-k8s.io
#
# Why it still exists: `helm upgrade` never touches crds/, so after a version
# bump a Helm-managed install needs this to move the CRD schemas forward. (Argo
# CD applies crds/ on every sync, so it has no such gap.)
#
# It deliberately does NOT install Gateway API (gateway.networking.k8s.io) CRDs.
# On OpenShift 4.19+ those are owned and continuously reconciled by the
# cluster-ingress-operator; the last step asserts nothing here touched them.
#
# The files are regenerated from the vendored upstream charts by
# hack/update-crds.sh; this script only applies them, so it needs no chart
# registry and runs on a disconnected bastion.
#
# Usage:
#   hack/install-crds.sh [--dry-run] [component ...]
#
#   components: envoy-gateway  ai-gateway  lws  kserve
#   default:    all four
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FIELD_MANAGER="envoy-ai-stack"

DRY_RUN=false
COMPONENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    envoy-gateway|ai-gateway|lws|kserve) COMPONENTS+=("$1") ;;
    # Print the leading comment block, whatever length it grows to.
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "!! unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ ${#COMPONENTS[@]} -eq 0 ]] && COMPONENTS=(envoy-gateway ai-gateway lws kserve)

APPLY=(kubectl apply --server-side --field-manager="${FIELD_MANAGER}" -f -)
if [[ "${DRY_RUN}" == true ]]; then
  APPLY=(kubectl apply --server-side --field-manager="${FIELD_MANAGER}" --dry-run=server -f -)
  echo ">> DRY RUN: nothing will be persisted"
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! required tool not found: $1" >&2; exit 1; }; }
need helm
need kubectl

wants() { local c; for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }

echo ">> Preflight: Gateway API CRDs must already exist and be provider-managed"
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  cat >&2 <<'MSG'
!! Gateway API CRDs are not installed on this cluster.

   This script will not install them: on a shared cluster that is a
   cluster-wide change that belongs to the cluster administrator.

   On OpenShift, enable the platform's own Gateway API support instead. On a
   cluster you own exclusively, install them from the upstream chart:

     helm template eg-crds hack/charts/gateway-crds-helm-v1.9.1.tgz \
       --set crds.gatewayAPI.enabled=true \
       --set crds.gatewayAPI.channel=standard \
       --set crds.envoyGateway.enabled=false | kubectl apply --server-side -f -
MSG
  exit 1
fi

GWAPI_VERSION="$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
GWAPI_CHANNEL="$(kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')"
echo "   found Gateway API ${GWAPI_VERSION} (${GWAPI_CHANNEL} channel) -- leaving it untouched"

case "${GWAPI_VERSION}" in
  v1.[4-9]*|v1.[1-9][0-9]*) ;;
  *) echo "!! Envoy Gateway expects Gateway API v1.4 or newer; found ${GWAPI_VERSION}" >&2; exit 1 ;;
esac

if [[ "${GWAPI_CHANNEL}" == "standard" ]]; then
  echo "   note: standard channel -- TCPRoute/TLSRoute/UDPRoute/XListenerSet are absent."
  echo "         Envoy Gateway detects this at startup and disables those watches."
fi

if wants kserve; then
  echo
  echo ">> Preflight: cert-manager must be installed (llmisvc's webhook certificate)"
  if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "!! cert-manager is not installed. The llmisvc chart creates a cert-manager" >&2
    echo "   Certificate and Issuer for its webhook; without cert-manager the" >&2
    echo "   controller never goes Ready. On OpenShift, install the cert-manager" >&2
    echo "   Operator for Red Hat OpenShift." >&2
    exit 1
  fi
  echo "   found $(kubectl get crd certificates.cert-manager.io -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')"
fi

# Every file under a chart's crds/, concatenated as one multi-document stream.
chart_crds() { local f; for f in "${REPO_ROOT}/charts/$1/crds/"*.yaml; do cat "$f"; echo; done; }

if wants envoy-gateway; then
  echo
  echo ">> Envoy Gateway + InferencePool CRDs (charts/envoy-gateway-openshift/crds)"
  chart_crds envoy-gateway-openshift | "${APPLY[@]}"
fi

if wants ai-gateway; then
  echo
  echo ">> Envoy AI Gateway CRDs (charts/envoy-ai-gateway-openshift/crds)"
  chart_crds envoy-ai-gateway-openshift | "${APPLY[@]}"
fi

if wants lws; then
  echo
  echo ">> LeaderWorkerSet CRDs (the lws subchart's own crds/)"
  helm show crds "${REPO_ROOT}/charts/lws-openshift" | "${APPLY[@]}"
fi

if wants kserve; then
  echo
  echo ">> KServe + llm-d CRDs (charts/kserve-llmisvc-openshift/crds)"
  chart_crds kserve-llmisvc-openshift | "${APPLY[@]}"
fi

echo
echo ">> Done. CRDs owned by this stack:"
kubectl get crd -o name \
  | grep -E 'gateway\.envoyproxy\.io|aigateway\.envoyproxy\.io|leaderworkerset\.x-k8s\.io|disaggregatedset\.x-k8s\.io|serving\.kserve\.io|inference\.networking\.(x-)?k8s\.io|llm-d\.ai' \
  | sed 's|customresourcedefinition.apiextensions.k8s.io/|   |'

echo
echo ">> Confirming no Gateway API CRD was modified by ${FIELD_MANAGER}:"
for crd in gateways gatewayclasses httproutes grpcroutes referencegrants; do
  if kubectl get "crd/${crd}.gateway.networking.k8s.io" --show-managed-fields \
       -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null | grep -q "${FIELD_MANAGER}"; then
    echo "   !! UNEXPECTED: ${FIELD_MANAGER} owns fields on ${crd}.gateway.networking.k8s.io" >&2
    exit 1
  fi
done
echo "   clean -- Gateway API CRDs still owned by the cluster operator only"
