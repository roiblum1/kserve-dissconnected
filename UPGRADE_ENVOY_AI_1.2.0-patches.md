# Envoy AI Gateway v1.2.0 with the three patches

Written 2026-10-11. [`UPGRADE-v1.2.0.md`](UPGRADE-v1.2.0.md) is the upgrade to
stock v1.2.0. This page is the step after it: running a build of v1.2.0 that
carries the patches in `patches/agent-router-v1.2.0/`.

## Do you need it

Stock v1.2.0 serves models. The patched build is needed for these:

| You use | Patch | Without it | Image |
|---|---|---|---|
| A quota on a model that aigw-ui serves from two or more sites | 0001 | Nothing is counted and nobody is refused | controller |
| Cheaper cached tokens on `/anthropic/v1/messages` to vLLM | 0002 | A cached prompt is charged in full | extproc |
| Flow control in the scheduler (`model.flowControl` in `charts/llm-model`), so best-effort requests wait behind the others | 0003 | Every request waits out its timeout and gets 429 | controller |

`/v1/chat/completions` is not touched by 0002. A cluster with one site, no
Anthropic clients and no flow control can stay on stock v1.2.0.

## The patches

All are against the tag `v1.2.0` of `theagentrouter/agent-router`.

| Patch | Upstream | Drop it when |
|---|---|---|
| `0001-extensionserver-apply-QuotaPolicy-to-per-backend-clu.patch` | Pull request #2833, open | A release contains it |
| `0002-translator-keep-cached-tokens-on-Anthropic-requests-.patch` | Pull request #2837, open. That one also covers cache writes; the file here is the first version, which is what was tested on the lab | A release contains it |
| `0003-fix-add-one-InferencePool-ext-proc-filter-per-pool-n.patch` | Pull request #2595, merged 2026-10-08, in no release yet. A backport | The first release after v1.2.0 |

## The images

| Image | Built from |
|---|---|
| `docker.io/roi12345/ai-gateway-controller:v1.2.0-patched.1` | v1.2.0 + 0001, 0002, 0003 |
| `docker.io/roi12345/ai-gateway-extproc:v1.2.0-patched.1` | the same commit |

Both must come from one commit with one version string. The binaries call
themselves `v1.2.0`; a controller and an extproc that disagree on the
version refuse each other's configuration.

A new patch set gets a new tag (`v1.2.0-patched.2`). Never push over a tag.

### Building them

CI does it: `.github/workflows/gateway-images.yml` runs when a patch or the
workflow changes, and pushes both images under `IMAGE_TAG`. It never
overwrites a tag, so a new patch set needs a new `IMAGE_TAG` there. By hand it
is the same steps, and needs the internet, or a Go module proxy, once:

```bash
git clone https://github.com/theagentrouter/agent-router && cd agent-router
git checkout -b site-v1.2.0 v1.2.0
git am /path/to/patches/agent-router-v1.2.0/*.patch
go test ./internal/extensionserver/ ./internal/translator/

V="-X github.com/envoyproxy/ai-gateway/internal/version.version=v1.2.0-0-g$(git rev-parse --short=8 HEAD)"
for c in controller extproc; do
  mkdir -p out/$c
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w $V" -o out/$c/app ./cmd/$c
  cat > out/$c/Dockerfile <<'DOCKERFILE'
FROM gcr.io/distroless/static-debian12:nonroot
COPY --chmod=755 app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
DOCKERFILE
  podman build --platform linux/amd64 -t docker.io/roi12345/ai-gateway-$c:v1.2.0-patched.1 out/$c
  podman push docker.io/roi12345/ai-gateway-$c:v1.2.0-patched.1
done
```

## Moving a cluster to the patched build

1. Mirror the two images with the others. They are in `mirror-config.yaml`,
   next to the stock ones, which stay for the way back.
2. Point the chart at them. Under Argo CD these four values go into the
   Application; with plain Helm:

   ```bash
   helm upgrade envoy-ai-gateway charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system --wait \
     --set ai-gateway.controller.image.repository=docker.io/roi12345/ai-gateway-controller \
     --set ai-gateway.controller.image.tag=v1.2.0-patched.1 \
     --set ai-gateway.extProc.image.repository=docker.io/roi12345/ai-gateway-extproc \
     --set ai-gateway.extProc.image.tag=v1.2.0-patched.1
   ```

   An `ImageDigestMirrorSet` cannot do this for you: it rewrites the registry
   and repository and keeps the tag, and these have another repository and tag.
3. Restart what holds the old extproc and the old filter chain:

   ```bash
   oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
   oc rollout restart -n envoy-gateway-system deployment -l app.kubernetes.io/component=proxy
   ```

   Running requests on the restarted proxy pods are cut after the drain time.

## Checking it

```bash
# both images
oc get deploy -n envoy-ai-gateway-system -o jsonpath='{..image}{"\n"}'
oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
  -o jsonpath='{..containers[*].image}{"\n"}'

# 0003: every name with "endpointpicker" in the proxy's configuration, counted.
# Stock v1.2.0 shows a model's scheduler filter once per route match (16 on
# the lab); the patched build shows it once per listener.
POD=$(oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy -o name | head -1)
oc port-forward -n envoy-gateway-system $POD 19000:19000 &
curl -s localhost:19000/config_dump | grep -o '"name": "[^"]*endpointpicker[^"]*"' | sort | uniq -c
```

For 0001, give a tenant a small quota on a model served from two sites and
send past it: the counter rises and the tenant gets 429. For 0002, send the
same long prompt twice on `/anthropic/v1/messages`: the second answer shows
`cache_read_input_tokens` above 0. aigw-ui's self-test covers both.

What the lab measured with each patch is in
[`UPGRADE-v1.2.0.md`](UPGRADE-v1.2.0.md), "The three patches".

## Going back

Set the four values back to `docker.io/envoyproxy/ai-gateway-controller`,
`docker.io/envoyproxy/ai-gateway-extproc` and an empty tag, and run the two
restarts again. Before that, turn `model.flowControl.enabled` off on every
model: with stock v1.2.0 it answers every request with 429.

## Not done


- Patch 0002 here is the first version. Cache writes on the Anthropic path
  are still charged as plain input.
- Upstream pull request #2766 (a changed `QuotaPolicy` did not always reach
  the proxy; merged 2026-10-09, in no release) is not in this build.
