#!/usr/bin/env bash
#
# Installs ONLY the CRDs this stack owns:
#   * gateway.envoyproxy.io          (Envoy Gateway)
#   * aigateway.envoyproxy.io        (Envoy AI Gateway)
#   * leaderworkerset.x-k8s.io       (LeaderWorkerSet)
#   * disaggregatedset.x-k8s.io      (LeaderWorkerSet)
#   * serving.kserve.io              (KServe LLMInferenceService)
#   * inference.networking.k8s.io    (Gateway API Inference Extension)
#   * inference.networking.x-k8s.io  (Gateway API Inference Extension)
#   * llm-d.ai                       (llm-d router)
#
# It deliberately does NOT install Gateway API (gateway.networking.k8s.io) CRDs.
# On OpenShift 4.19+ those are owned and continuously reconciled by the
# cluster-ingress-operator; a second copy would fight the operator and affect
# every other tenant on the cluster. The last step of this script asserts that
# nothing here touched them.
#
# CRDs are applied out of band rather than from the Helm charts because they are
# cluster-scoped and must outlive `helm uninstall`. Two of the upstream charts
# would otherwise delete them:
#   * lws ships them under crds/, which `helm install` overwrites via
#     server-side apply on Helm 4 and `helm upgrade` never updates at all; and
#   * kserve-llmisvc-resources renders the Inference Extension and llm-d CRDs
#     into templates/ when createGIECRDs=true, so `helm uninstall` would delete
#     them along with every InferencePool on the cluster.
#
# Every chart is read from hack/charts/ or the vendored charts/*/charts/ copy
# when present, so this script runs unchanged on a disconnected bastion. It
# falls back to pulling from the upstream OCI registries only if a vendored
# tarball is missing.
#
# Usage:
#   hack/install-crds.sh [--dry-run] [--emit DIR] [component ...]
#
#   components: envoy-gateway  ai-gateway  lws  kserve
#   default:    all four
#
#   --emit DIR  Write the CRDs to DIR as plain YAML instead of applying them,
#               one file per component. This is how crds/ is generated, which
#               is the source Argo CD syncs -- Argo CD cannot run this script,
#               so the CRDs have to exist as manifests in git. Emit mode needs
#               no cluster: it skips every preflight and assertion that reads
#               one, so it runs on a disconnected bastion with no kubeconfig.
#               Re-emitting is idempotent; `git diff crds/` after a version
#               bump is the CRD half of the upgrade review.
#
# Environment overrides (used by UPGRADE.md's rollback step):
#   EG_VERSION AIGW_VERSION LWS_VERSION KSERVE_VERSION
#   CHART_REPO KSERVE_CHART_REPO LWS_CHART_REPO
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EG_VERSION="${EG_VERSION:-v1.9.1}"
AIGW_VERSION="${AIGW_VERSION:-v1.1.0}"
LWS_VERSION="${LWS_VERSION:-v0.10.0}"
KSERVE_VERSION="${KSERVE_VERSION:-v0.21.0-rc1}"

CHART_REPO="${CHART_REPO:-oci://docker.io/envoyproxy}"
KSERVE_CHART_REPO="${KSERVE_CHART_REPO:-oci://ghcr.io/kserve/charts}"
LWS_CHART_REPO="${LWS_CHART_REPO:-oci://registry.k8s.io/lws/charts}"

FIELD_MANAGER="envoy-ai-stack"

DRY_RUN=false
EMIT_DIR=""
COMPONENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --emit) EMIT_DIR="${2:-}"; [[ -n "${EMIT_DIR}" ]] || { echo "!! --emit needs a directory" >&2; exit 2; }; shift ;;
    --emit=*) EMIT_DIR="${1#*=}" ;;
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

# Where each component's CRDs go: the cluster, or a file under --emit DIR.
# The file gets a provenance header naming the chart it came from and the
# command that regenerates it; the body is exactly what apply mode would send.
sink() {
  local name="$1" title="$2"
  if [[ -z "${EMIT_DIR}" ]]; then
    "${APPLY[@]}"
    return
  fi
  local out="${EMIT_DIR}/${name}.yaml"
  {
    echo "# ${title}"
    echo "#"
    echo "# GENERATED -- do not edit. Regenerate with:"
    echo "#   hack/install-crds.sh --emit crds"
    echo "#"
    echo "# Applied by Argo CD, or by hack/install-crds.sh without --emit."
    echo "# Gateway API (gateway.networking.k8s.io) is deliberately absent: those"
    echo "# CRDs belong to the cluster-ingress-operator. See CLAUDE.md invariant 2."
    cat
  } > "${out}"
  printf '   wrote %-28s %s CRD(s)\n' "${out}" "$(grep -c '^kind: CustomResourceDefinition' "${out}")"
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! required tool not found: $1" >&2; exit 1; }; }
need helm
need python3
[[ -n "${EMIT_DIR}" ]] || need kubectl

wants() { local c; for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }

# Resolve a chart to a local vendored tarball if we shipped one, else to its
# upstream OCI reference. Prints "<ref>|<version-args>".
chart_ref() {
  local local_path="$1" oci_repo="$2" name="$3" version="$4"
  if [[ -f "${local_path}" ]]; then
    printf '%s|' "${local_path}"
  else
    echo "   (no vendored ${name}-${version}.tgz; pulling from ${oci_repo})" >&2
    printf '%s/%s|--version=%s' "${oci_repo}" "${name}" "${version}"
  fi
}

# Keep only CustomResourceDefinitions, and only those in the named API groups.
# Everything else the chart renders is discarded.
#
# The kept documents are re-emitted as the UPSTREAM TEXT, not as a re-dump of
# the parsed object: yaml.compose_all gives each document's byte range, so the
# original formatting, key order and `# Source:` comments survive. That matters
# because crds/ is committed -- `git diff crds/` after a version bump then
# shows the upstream schema change and nothing else. Re-dumping added ~20% of
# whitespace and reordered every key, which made the diff unreadable.
only_crds() {
  python3 -c '
import sys, yaml
groups = set(sys.argv[1:])
text = sys.stdin.read()
kept = 0
prev = 0
for node in yaml.compose_all(text):
    if node is None:
        continue
    start, end = node.start_mark.index, node.end_mark.index
    lead, prev = text[prev:start], end
    doc = yaml.safe_load(text[start:end])
    if not doc or doc.get("kind") != "CustomResourceDefinition":
        continue
    if groups and doc["spec"]["group"] not in groups:
        continue
    comments = [l for l in lead.splitlines() if l.lstrip().startswith("#")]
    print("---")
    for l in comments:
        print(l)
    print(text[start:end].rstrip("\n"))
    kept += 1
if not kept:
    sys.exit("!! no CRDs matched groups: " + ", ".join(sorted(groups)))
' "$@"
}

if [[ -n "${EMIT_DIR}" ]]; then
  mkdir -p "${EMIT_DIR}"
  echo ">> EMIT MODE: writing YAML to ${EMIT_DIR}/, no cluster is contacted"
  echo "   (skipping the Gateway API and cert-manager preflights, which need one)"
fi

if [[ -z "${EMIT_DIR}" ]]; then
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
  *) echo "!! Envoy Gateway ${EG_VERSION} expects Gateway API v1.4 or newer; found ${GWAPI_VERSION}" >&2; exit 1 ;;
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
fi  # end of cluster-only preflights

if wants envoy-gateway; then
  echo
  echo ">> Envoy Gateway CRDs (${EG_VERSION}, gateway.envoyproxy.io only)"
  IFS='|' read -r ref vers <<<"$(chart_ref \
    "${REPO_ROOT}/hack/charts/gateway-crds-helm-${EG_VERSION}.tgz" \
    "${CHART_REPO}" gateway-crds-helm "${EG_VERSION}")"
  helm template envoy-gateway-crds "${ref}" ${vers:+"${vers}"} \
    --set crds.gatewayAPI.enabled=false \
    --set crds.envoyGateway.enabled=true \
    | only_crds gateway.envoyproxy.io \
    | sink envoy-gateway "Envoy Gateway ${EG_VERSION} CRDs -- gateway.envoyproxy.io (from gateway-crds-helm)"
fi

if wants ai-gateway; then
  echo
  echo ">> Envoy AI Gateway CRDs (${AIGW_VERSION}, aigateway.envoyproxy.io only)"
  IFS='|' read -r ref vers <<<"$(chart_ref \
    "${REPO_ROOT}/hack/charts/ai-gateway-crds-helm-${AIGW_VERSION}.tgz" \
    "${CHART_REPO}" ai-gateway-crds-helm "${AIGW_VERSION}")"
  helm template envoy-ai-gateway-crds "${ref}" ${vers:+"${vers}"} \
    | only_crds aigateway.envoyproxy.io \
    | sink ai-gateway "Envoy AI Gateway ${AIGW_VERSION} CRDs -- aigateway.envoyproxy.io (from ai-gateway-crds-helm)"
fi

if wants lws; then
  echo
  echo ">> LeaderWorkerSet CRDs (${LWS_VERSION})"
  # The lws chart ships its CRDs under crds/, so they come out of `helm show
  # crds` rather than `helm template`. Read them from the wrapper chart, whose
  # vendored subchart is the same tarball the install uses.
  if [[ -d "${REPO_ROOT}/charts/lws-openshift" ]] \
     && [[ -f "${REPO_ROOT}/charts/lws-openshift/charts/lws-${LWS_VERSION}.tgz" ]]; then
    helm show crds "${REPO_ROOT}/charts/lws-openshift"
  else
    echo "   (no vendored lws-${LWS_VERSION}.tgz; pulling from ${LWS_CHART_REPO})" >&2
    helm show crds "${LWS_CHART_REPO}/lws" --version "${LWS_VERSION}"
  fi | only_crds leaderworkerset.x-k8s.io disaggregatedset.x-k8s.io \
     | sink lws "LeaderWorkerSet ${LWS_VERSION} CRDs -- leaderworkerset.x-k8s.io, disaggregatedset.x-k8s.io (from the lws chart's crds/)"
fi

if wants kserve; then
  echo
  echo ">> KServe LLMInferenceService CRDs (${KSERVE_VERSION}, serving.kserve.io)"
  IFS='|' read -r ref vers <<<"$(chart_ref \
    "${REPO_ROOT}/hack/charts/kserve-llmisvc-crd-${KSERVE_VERSION}.tgz" \
    "${KSERVE_CHART_REPO}" kserve-llmisvc-crd "${KSERVE_VERSION}")"
  # -n kserve matters: the llminferenceservices CRD's conversion webhook and
  # cert-manager CA injection are hardcoded to the `kserve` namespace upstream,
  # which is why kserve-llmisvc-openshift refuses to install anywhere else.
  helm template kserve-llmisvc-crd "${ref}" ${vers:+"${vers}"} -n kserve \
    | only_crds serving.kserve.io \
    | sink kserve-llmisvc "KServe ${KSERVE_VERSION} CRDs -- serving.kserve.io (from kserve-llmisvc-crd)"

  echo
  echo ">> Gateway API Inference Extension + llm-d CRDs (from kserve-llmisvc-resources ${KSERVE_VERSION})"
  # Rendered from the same chart the controller ships in, so the CRD schemas
  # always match the controller -- no separate GIE/llm-d version to track.
  IFS='|' read -r ref vers <<<"$(chart_ref \
    "${REPO_ROOT}/charts/kserve-llmisvc-openshift/charts/kserve-llmisvc-resources-${KSERVE_VERSION}.tgz" \
    "${KSERVE_CHART_REPO}" kserve-llmisvc-resources "${KSERVE_VERSION}")"
  helm template gie "${ref}" ${vers:+"${vers}"} -n kserve \
    --set kserve.llmisvc.createGIECRDs=true \
    | only_crds inference.networking.k8s.io inference.networking.x-k8s.io llm-d.ai \
    | sink kserve-gie-llmd "Gateway API Inference Extension + llm-d CRDs -- inference.networking.k8s.io, inference.networking.x-k8s.io, llm-d.ai (from kserve-llmisvc-resources ${KSERVE_VERSION}, createGIECRDs=true)"
fi

if [[ -n "${EMIT_DIR}" ]]; then
  echo
  echo ">> Asserting no Gateway API CRD was emitted (CLAUDE.md invariant 2):"
  if grep -lE '^  group: gateway\.networking\.k8s\.io$' "${EMIT_DIR}"/*.yaml 2>/dev/null; then
    echo "   !! the files above contain a Gateway API CRD -- that group belongs to" >&2
    echo "      the cluster-ingress-operator and must never be emitted here" >&2
    exit 1
  fi
  echo "   clean -- $(grep -h '^kind: CustomResourceDefinition' "${EMIT_DIR}"/*.yaml | wc -l | tr -d ' ') CRDs across $(ls -1 "${EMIT_DIR}"/*.yaml | wc -l | tr -d ' ') files, none in gateway.networking.k8s.io"
  echo
  echo ">> Done. Commit ${EMIT_DIR}/ and let Argo CD sync it; see ${EMIT_DIR}/argocd/application.yaml."
  exit 0
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
