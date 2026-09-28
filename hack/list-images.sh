#!/usr/bin/env bash
#
# Prints every container image the charts in this repo reference, one per line,
# fully qualified. This is the source of truth for mirror-config.yaml -- run it
# after any version bump and diff the result.
#
#   hack/list-images.sh                       # just the list
#   hack/list-images.sh --check               # diff against mirror-config.yaml
#   hack/list-images.sh --annotate            # list with resolved digests
#
# Nothing is hardcoded here: every reference comes out of `helm template`. Two
# extraction quirks this exists to handle:
#   * the ext_proc sidecar appears only as `--extProcImage=<ref>` on the AI
#     Gateway controller, because its mutating webhook injects the container at
#     pod-creation time -- it is never an `image:` key;
#   * some upstream references are unqualified (`kserve/llmisvc-controller`),
#     and are prefixed with docker.io/ so the mirror entry is unambiguous.
#
# Two image defaults are compiled into the Envoy Gateway Go binary (the data
# plane and the shutdown-manager). They show up here only because
# charts/envoy-gateway-openshift/values.yaml pins both; if those overrides are
# ever removed, this list silently loses them. See UPGRADE.md step 4.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! required tool not found: $1" >&2; exit 1; }; }
need helm
need python3

render() {
  # chart, namespace, extra args...
  local chart="$1" ns="$2"; shift 2
  helm template img "charts/${chart}" -n "${ns}" "$@" 2>/dev/null
}

images() {
  {
    render envoy-gateway-openshift envoy-gateway-system \
      -f charts/envoy-gateway-openshift/values-inference-pool.yaml
    render envoy-ai-gateway-openshift envoy-ai-gateway-system \
      -f charts/envoy-ai-gateway-openshift/values-kserve.yaml
    render lws-openshift lws-system
    render kserve-llmisvc-openshift kserve
    render kserve-runtime-configs-openshift kserve
  } | python3 -c '
import re, sys
seen = set()
for line in sys.stdin:
    # Two shapes appear in rendered manifests: a YAML `image:` key, and an
    # `--...Image=<ref>` flag (that is how the AI Gateway controller is told
    # which ext_proc image to inject -- it never appears as an image: key).
    ref_re = r'"'"'([A-Za-z0-9][\w.\-]*(?:\.[\w.\-]+)?(?:/[\w.\-]+)+(?::[\w.\-]+)?(?:@sha256:[0-9a-f]{64})?)'"'"'
    m = (re.search(r'"'"'(?<!\w)image:\s*"?'"'"' + ref_re + r'"'"'"?\s*$'"'"', line)
         or re.search(r'"'"'--\w*[Ii]mage='"'"' + ref_re + r'"'"'"?\s*$'"'"', line))
    if not m:
        continue
    ref = m.group(1)
    # Fully qualify anything that does not start with a registry host.
    host = ref.split("/")[0]
    if "." not in host and ":" not in host:
        ref = "docker.io/" + ref
    seen.add(ref)
print("\n".join(sorted(seen)))
'
}

case "${1:-}" in
  --check)
    tmp_have="$(mktemp)"; tmp_want="$(mktemp)"
    trap 'rm -f "$tmp_have" "$tmp_want"' EXIT
    # Compare on repo:tag, ignoring any @sha256 suffix, because
    # mirror-config.yaml lists tags and the charts sometimes pin digests.
    images | sed 's/@sha256:.*//' | sort -u >"$tmp_want"
    python3 -c '
import sys, yaml
d = yaml.safe_load(open("mirror-config.yaml"))
for e in (d["mirror"].get("additionalImages") or []):
    print(e["name"].split("@")[0])
' | sort -u >"$tmp_have"
    if diff -u "$tmp_have" "$tmp_want" >/dev/null; then
      echo "OK: mirror-config.yaml matches the charts ($(wc -l <"$tmp_want" | tr -d ' ') images)"
    else
      echo "MISMATCH between mirror-config.yaml (-) and the charts (+):"
      diff -u "$tmp_have" "$tmp_want" | tail -n +4
      echo
      echo "Images the charts reference but mirror-config.yaml omits would not be"
      echo "mirrored and would fail to pull on a disconnected cluster."
      exit 1
    fi
    ;;
  --annotate)
    while read -r ref; do
      printf '%-72s %s\n' "$ref" "$("${REPO_ROOT}/hack/resolve-digest.sh" "$ref" 2>/dev/null || echo '(unresolved)')"
    done < <(images)
    ;;
  ""|--list) images ;;
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" ;;
  *) echo "!! unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac
