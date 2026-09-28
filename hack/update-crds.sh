#!/usr/bin/env bash
#
# Regenerates the crds/ directory of every wrapper chart from the vendored
# upstream charts. Run it after every version bump; `--check` fails if the
# committed files have drifted from what the vendored charts produce.
#
#   hack/update-crds.sh            # rewrite charts/*/crds/
#   hack/update-crds.sh --check    # verify only, write nothing (CI / review)
#
# What lands where -- one Argo CD Application per chart directory:
#
#   charts/envoy-gateway-openshift/crds/
#       gateway.envoyproxy.io            from hack/charts/gateway-crds-helm
#       inference.networking.k8s.io      from kserve-llmisvc-resources
#       inference.networking.x-k8s.io    (createGIECRDs=true)
#     InferencePool lives here, not with KServe, because Envoy Gateway is
#     configured to watch it (extensionManager.backendResources) and must find
#     the CRD when it starts.
#
#   charts/envoy-ai-gateway-openshift/crds/
#       aigateway.envoyproxy.io          from hack/charts/ai-gateway-crds-helm
#
#   charts/kserve-llmisvc-openshift/crds/
#       serving.kserve.io                from hack/charts/kserve-llmisvc-crd
#       llm-d.ai                         from kserve-llmisvc-resources
#
#   charts/lws-openshift                 nothing: upstream's lws chart already
#                                        ships its CRDs in its own crds/.
#
# Gateway API (gateway.networking.k8s.io) is NEVER emitted -- those CRDs belong
# to the cluster-ingress-operator (CLAUDE.md invariant 2). The script asserts
# it on every run.
#
# Every CRD gets two annotations the upstream text lacks (Helm never templates
# crds/, so they have to be baked into the file):
#
#   argocd.argoproj.io/sync-wave: "-10"
#       before everything else in the same Application, so the CRD is
#       Established before any custom resource of its kind is applied.
#   argocd.argoproj.io/sync-options: ServerSideApply=true,Prune=false,Delete=false
#       ServerSideApply: the big CRDs (llminferenceservices ~2.7 MB) exceed the
#         262144-byte last-applied-configuration annotation client-side apply
#         needs, so a client-side sync fails with "Too long".
#       Prune=false / Delete=false: removing a CRD garbage-collects every
#         custom resource of that kind, cluster-wide, for every tenant. A CRD
#         dropped upstream or an Application deleted must never do that.
#
# One file per CRD, named after the CRD. Not cosmetic: Helm refuses to load a
# chart file over 5 MiB (MaxDecompressedFileSize), and the serving.kserve.io
# CRDs alone are 5.4 MB together.
#
# Versions are read from the wrapper charts' own Chart.yaml dependencies, so a
# version bump is: edit Chart.yaml, drop the new tarballs in charts/*/charts/
# and hack/charts/, run this. See UPGRADE.md.
#
# Needs helm and python3 with PyYAML. No cluster: runs on a disconnected
# bastion. Falls back to pulling a CRD chart from its upstream OCI registry
# only when the vendored tarball is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CHECK=false
case "${1:-}" in
  --check) CHECK=true ;;
  "") ;;
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "!! unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! required tool not found: $1" >&2; exit 1; }; }
need helm
need python3

EG_CHART=charts/envoy-gateway-openshift
AIGW_CHART=charts/envoy-ai-gateway-openshift
KSERVE_CHART=charts/kserve-llmisvc-openshift

# Version of dependency $2 in wrapper chart $1, straight from its Chart.yaml.
dep_version() {
  python3 -c '
import sys, yaml
for d in yaml.safe_load(open(sys.argv[1] + "/Chart.yaml"))["dependencies"]:
    if d["name"] == sys.argv[2]:
        print(d["version"]); break
else:
    sys.exit("!! " + sys.argv[2] + " is not a dependency of " + sys.argv[1])
' "$1" "$2"
}

EG_VERSION="$(dep_version "${EG_CHART}" gateway-helm)"
AIGW_VERSION="$(dep_version "${AIGW_CHART}" ai-gateway-helm)"
KSERVE_VERSION="$(dep_version "${KSERVE_CHART}" kserve-llmisvc-resources)"

# A chart reference for `helm template`: the vendored tarball if present, else
# the upstream OCI reference plus --version.
chart_ref() {
  local path="$1" oci="$2" version="$3"
  if [[ -f "${path}" ]]; then
    REF=("${path}")
  else
    echo "   (no vendored $(basename "${path}"); pulling ${oci}:${version})" >&2
    REF=("${oci}" --version "${version}")
  fi
}

OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT

# Reads a multi-document render on stdin and writes each CRD whose API group is
# listed into $1/<crd-name>.yaml, as the UPSTREAM TEXT plus the two annotations
# above. The text is spliced, not re-dumped, so `git diff` after a bump shows
# only the upstream schema change. The result is re-parsed and compared with
# the upstream object to prove the splice changed nothing else.
SPLIT_PY="${OUT}/split_crds.py"
cat > "${SPLIT_PY}" <<'PY'
import os, sys, yaml
outdir, source, groups = sys.argv[1], sys.argv[2], set(sys.argv[3:])
ANN = {
    "argocd.argoproj.io/sync-wave": "-10",
    "argocd.argoproj.io/sync-options": "ServerSideApply=true,Prune=false,Delete=false",
}
text = sys.stdin.read()
kept = 0
for node in yaml.compose_all(text):
    if node is None:
        continue
    body = text[node.start_mark.index:node.end_mark.index].rstrip("\n")
    doc = yaml.safe_load(body)
    if not doc or doc.get("kind") != "CustomResourceDefinition":
        continue
    if doc["spec"]["group"] not in groups:
        continue
    name = doc["metadata"]["name"]
    if doc["metadata"].get("annotations", {}).keys() & ANN.keys():
        sys.exit(f"!! {name} already sets an argocd.argoproj.io annotation upstream; review before overwriting it")
    lines = body.split("\n")
    i = lines.index("metadata:")
    add = [f'    {k}: "{v}"' if k.endswith("sync-wave") else f"    {k}: {v}" for k, v in ANN.items()]
    j = i + 1
    while j < len(lines) and lines[j].startswith("  "):
        if lines[j] == "  annotations:":
            lines[j + 1:j + 1] = add
            break
        j += 1
    else:
        lines[i + 1:i + 1] = ["  annotations:"] + add
    out = "\n".join(lines)
    check = yaml.safe_load(out)
    got = check["metadata"].pop("annotations")
    want = dict(doc["metadata"].pop("annotations", {}), **ANN)
    if got != want or check != doc:
        sys.exit(f"!! annotation splice altered {name}; refusing to write it")
    with open(os.path.join(outdir, name + ".yaml"), "w") as f:
        f.write("# GENERATED by hack/update-crds.sh -- do not edit.\n")
        f.write(f"# From {source}.\n")
        f.write("---\n" + out + "\n")
    kept += 1
if not kept:
    sys.exit("!! no CRDs matched groups: " + ", ".join(sorted(groups)))
print(f"   {kept:>2} CRD(s)  {', '.join(sorted(groups))}")
PY
split_crds() { python3 "${SPLIT_PY}" "$@"; }

mkdir -p "${OUT}/${EG_CHART}/crds" "${OUT}/${AIGW_CHART}/crds" "${OUT}/${KSERVE_CHART}/crds"

echo ">> ${EG_CHART}/crds"
chart_ref "hack/charts/gateway-crds-helm-${EG_VERSION}.tgz" oci://docker.io/envoyproxy/gateway-crds-helm "${EG_VERSION}"
helm template envoy-gateway-crds "${REF[@]}" \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | split_crds "${OUT}/${EG_CHART}/crds" "gateway-crds-helm ${EG_VERSION}" gateway.envoyproxy.io

chart_ref "${KSERVE_CHART}/charts/kserve-llmisvc-resources-${KSERVE_VERSION}.tgz" oci://ghcr.io/kserve/charts/kserve-llmisvc-resources "${KSERVE_VERSION}"
GIE_RENDER="$(helm template gie "${REF[@]}" -n kserve --set kserve.llmisvc.createGIECRDs=true)"
split_crds "${OUT}/${EG_CHART}/crds" "kserve-llmisvc-resources ${KSERVE_VERSION} (createGIECRDs=true)" \
  inference.networking.k8s.io inference.networking.x-k8s.io <<<"${GIE_RENDER}"

echo ">> ${AIGW_CHART}/crds"
chart_ref "hack/charts/ai-gateway-crds-helm-${AIGW_VERSION}.tgz" oci://docker.io/envoyproxy/ai-gateway-crds-helm "${AIGW_VERSION}"
helm template envoy-ai-gateway-crds "${REF[@]}" \
  | split_crds "${OUT}/${AIGW_CHART}/crds" "ai-gateway-crds-helm ${AIGW_VERSION}" aigateway.envoyproxy.io

echo ">> ${KSERVE_CHART}/crds"
chart_ref "hack/charts/kserve-llmisvc-crd-${KSERVE_VERSION}.tgz" oci://ghcr.io/kserve/charts/kserve-llmisvc-crd "${KSERVE_VERSION}"
# -n kserve: the llminferenceservices CRD's conversion webhook and CA injection
# are hardcoded to `kserve` upstream, which is why the chart enforces that
# namespace (CLAUDE.md invariant 10).
helm template kserve-llmisvc-crd "${REF[@]}" -n kserve \
  | split_crds "${OUT}/${KSERVE_CHART}/crds" "kserve-llmisvc-crd ${KSERVE_VERSION}" serving.kserve.io
split_crds "${OUT}/${KSERVE_CHART}/crds" "kserve-llmisvc-resources ${KSERVE_VERSION} (createGIECRDs=true)" \
  llm-d.ai <<<"${GIE_RENDER}"

echo ">> Asserting no Gateway API CRD was emitted (CLAUDE.md invariant 2)"
if grep -lE '^  group: gateway\.networking\.k8s\.io$' "${OUT}"/charts/*/crds/*.yaml; then
  echo "!! the files above are Gateway API CRDs -- they belong to the cluster-ingress-operator" >&2
  exit 1
fi
echo "   clean"

rc=0
for chart in "${EG_CHART}" "${AIGW_CHART}" "${KSERVE_CHART}"; do
  if ${CHECK}; then
    if ! diff -r "${chart}/crds" "${OUT}/${chart}/crds" >/dev/null 2>&1; then
      echo "!! ${chart}/crds is out of date:" >&2
      diff -rq "${chart}/crds" "${OUT}/${chart}/crds" >&2 || true
      rc=1
    fi
  else
    # Replace wholesale, so a CRD dropped upstream disappears from git too.
    # (Its Prune=false annotation keeps Argo CD from deleting it on the cluster.)
    rm -rf "${chart}/crds"
    cp -r "${OUT}/${chart}/crds" "${chart}/crds"
  fi
done

if ${CHECK}; then
  [[ ${rc} -eq 0 ]] && echo ">> OK: every charts/*/crds/ matches the vendored charts"
  exit ${rc}
fi
echo ">> Wrote $(ls "${EG_CHART}/crds" "${AIGW_CHART}/crds" "${KSERVE_CHART}/crds" | grep -c '\.yaml$') CRD files. Review with: git diff --stat -- 'charts/*/crds'"
