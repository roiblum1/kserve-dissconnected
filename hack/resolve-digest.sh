#!/usr/bin/env bash
#
# Prints the manifest digest of an image reference without pulling it.
#
#   hack/resolve-digest.sh docker.io/envoyproxy/gateway:v1.9.1
#   hack/resolve-digest.sh $(hack/list-images.sh)     # one per line
#
# Anonymous access only -- fine for docker.io, ghcr.io and registry.k8s.io,
# which is everything this stack pulls. Needs network, so run it on the
# connected side before mirroring.
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "!! required tool not found: $1" >&2; exit 1; }; }
need curl

resolve() {
  local ref="$1" host rest repo tag realm svc api hdrs=()
  ref="${ref%%@*}"                      # drop any existing digest
  host="${ref%%/*}"; rest="${ref#*/}"
  repo="${rest%:*}"; tag="${rest##*:}"
  [[ "$rest" == "$repo" ]] && tag="latest"

  case "$host" in
    docker.io)       realm="https://auth.docker.io/token"; svc="registry.docker.io"; api="https://registry-1.docker.io" ;;
    ghcr.io)         realm="https://ghcr.io/token";        svc="ghcr.io";            api="https://ghcr.io" ;;
    registry.k8s.io) realm=""; api="https://registry.k8s.io" ;;
    quay.io)         realm=""; api="https://quay.io" ;;
    *)               realm=""; api="https://${host}" ;;
  esac

  if [[ -n "$realm" ]]; then
    local token
    token="$(curl -fsS "${realm}?service=${svc}&scope=repository:${repo}:pull" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')"
    hdrs=(-H "Authorization: Bearer ${token}")
  fi

  # -L: registry.k8s.io is a redirector to a regional backing registry.
  # ${hdrs[@]+...} because bash 3.2 (macOS) errors on an empty array under set -u.
  curl -fsSIL ${hdrs[@]+"${hdrs[@]}"} \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "${api}/v2/${repo}/manifests/${tag}" \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{d=$2} END{if (d) print d; else exit 1}'
}

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") <image-ref> [image-ref ...]" >&2
  exit 2
fi
for ref in "$@"; do
  if [[ $# -eq 1 ]]; then
    resolve "$ref"
  else
    printf '%-72s %s\n' "$ref" "$(resolve "$ref" || echo RESOLVE_FAILED)"
  fi
done
