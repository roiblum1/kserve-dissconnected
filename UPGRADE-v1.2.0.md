# Upgrade to Envoy Gateway v1.9.2 and Envoy AI Gateway v1.2.0

This is the record of one upgrade, written so that it can be repeated on a
disconnected cluster by someone who was not there. [`UPGRADE.md`](UPGRADE.md)
is the general procedure. This file is what that procedure produced for this
bump: what changed in the repository, what to mirror, the exact commands, what
went wrong on the way, and what was measured.

It was run on OpenShift 4.22 (Kubernetes 1.35) with plain Helm on 2026-10-10.
KServe stays at v0.21.0 and LeaderWorkerSet at v0.10.0.

| Component | Before | After |
|---|---|---|
| Envoy Gateway (`gateway-helm`) | v1.9.1 | **v1.9.2** |
| Envoy AI Gateway (`ai-gateway-helm`), now named Agent Router | v1.1.0 | **v1.2.0** |
| Envoy data plane | distroless-v1.39.1 | unchanged |
| Rate limit service | `ratelimit:8fe6ea42` | **`ratelimit:0482748e`** |
| KServe, LWS, llm-d presets | v0.21.0, v0.10.0 | unchanged |
| Gateway API | v1.4.1 standard, the cluster's | unchanged, not ours |
| InferencePool CRDs | v1.5.0, from KServe's chart | unchanged |

## What you need to know first

1. **Nothing is renamed.** Agent Router v1.2.0 keeps the API group
   `aigateway.envoyproxy.io`, the chart names and the image names.
2. **No API version is removed.** `v1alpha1` of `AIGatewayRoute`,
   `AIServiceBackend`, `BackendSecurityPolicy`, `GatewayConfig` and `MCPRoute`
   is still served, as in v1.1.0, and still deprecated. `QuotaPolicy` has only
   `v1alpha1`. No stored object has to be migrated.
3. **KServe pins v1.1.0, and this repo now runs v1.2.0.** That is a chosen
   deviation from "KServe leads the versions". It is recorded in
   `UPGRADE.md` §1 and in the README's version table.
4. **A request larger than 32 KB was refused before this change**, on every
   version. The chart now sets the limit. See
   [the request size limit](#the-request-size-limit).
5. **Three fixes are not in v1.2.0 and are carried as patches**, for a site
   that needs them. See [the three patches](#the-three-patches).

## What changed in this repository

| File | Change |
|---|---|
| `charts/envoy-gateway-openshift/Chart.yaml`, `Chart.lock` | `gateway-helm` v1.9.2 |
| `charts/envoy-gateway-openshift/charts/gateway-helm-v1.9.2.tgz` | vendored, replaces v1.9.1 |
| `charts/envoy-gateway-openshift/values.yaml` | shutdown-manager image `gateway:v1.9.2` |
| `charts/envoy-gateway-openshift/crds/` | regenerated: 8 files changed |
| `charts/envoy-ai-gateway-openshift/Chart.yaml`, `Chart.lock` | `ai-gateway-helm` v1.2.0 |
| `charts/envoy-ai-gateway-openshift/charts/ai-gateway-helm-v1.2.0.tgz` | vendored, replaces v1.1.0 |
| `charts/envoy-ai-gateway-openshift/crds/` | regenerated: 6 files changed |
| `charts/envoy-ai-gateway-openshift/values.yaml` | new: `gateway.clientTrafficPolicy`; new override: `ai-gateway.controller.mcp.sessionEncryption.seed` |
| `charts/envoy-ai-gateway-openshift/templates/gateway.yaml` | new object: `ClientTrafficPolicy` |
| `charts/*/values-mirror.yaml` | image tags |
| `hack/charts/` | `gateway-crds-helm-v1.9.2.tgz`, `ai-gateway-crds-helm-v1.2.0.tgz` |
| `mirror-config.yaml` | three image tags, see below |
| `patches/agent-router-v1.2.0/` | the three patches |

Checked and found unchanged, so nothing was edited for them:

- the extension-hook contract (`manifests/envoy-gateway-values.yaml` is
  identical in v1.1.0 and v1.2.0);
- `DefaultEnvoyProxyImage` in Envoy Gateway v1.9.2, still
  `distroless-v1.39.1` with the same digest;
- `DefaultShutdownManagerImage`, still the mutable `gateway-dev:latest`, so
  the pin in `values.yaml` is still needed;
- the `ListenerSet` probe: v1.9.2 has `listenerSetCRDExists`, so it starts on
  standard-channel Gateway API.

The InferencePool add-on example upstream gained
`provider.kubernetes.deploy.type: GatewayNamespace`, for a conformance test.
It is not taken: this stack runs the data plane in `envoy-gateway-system`.

## The two overrides this bump added

**`ai-gateway.controller.mcp.sessionEncryption.seed: default-insecure-seed`.**
v1.2.0 generates a random MCP session seed in the template when none is
given, and finds its earlier one with `lookup`. Argo CD renders without a
cluster, so every render has a new seed: the Application never becomes
Synced and the seed changes on each sync. Measured: two renders of v1.2.0
differ in exactly the Secret `ai-gateway-controller-mcp-session-encryption`.
The fixed value is what every release up to v1.1.0 used. It is public, and
acceptable only because this stack serves no `MCPRoute`. Before creating an
`MCPRoute`, create a Secret with a random `seed` key and set
`ai-gateway.controller.mcp.sessionEncryption.existingSecret`.

**`gateway.clientTrafficPolicy`**, a new object, described next.

## The request size limit

Envoy Gateway buffers at most 32 KiB of a request on a client connection
unless told otherwise. The AI Gateway has to buffer the whole body to read
the model name. Measured on the lab, before the change, on both v1.1.0 and
v1.2.0:

| Request body | Answer |
|---|---|
| 29 KB | 200 |
| 35 KB | **413** |

An agent's request with a long conversation is often several hundred KB, so
this refuses real traffic. The chart now creates a `ClientTrafficPolicy`
named `client-buffer-limit` on the Gateway with upstream's own values:
`connection.bufferLimit: 50Mi` and the two HTTP/2 windows at 16Mi and 24Mi.
After it, bodies of 47 KB, 690 KB and 3 MB were answered 200.

If a site already has a `ClientTrafficPolicy` on the same Gateway, two
policies on one target conflict. Either add these settings to the existing
policy and set `gateway.clientTrafficPolicy.create: false`, or remove the
old one. A policy on a single listener replaces the Gateway's on that
listener, so a peer listener with client certificates needs the same
`connection` and `http2` settings in its own policy.

## Disconnected: what to mirror

Mirror before upgrading, or the rollout stops in `ImagePullBackOff`.
`mirror-config.yaml` is already updated. The difference to the previous
list is three images:

```
docker.io/envoyproxy/gateway:v1.9.2                  was v1.9.1
docker.io/envoyproxy/ai-gateway-controller:v1.2.0    was v1.1.0
docker.io/envoyproxy/ai-gateway-extproc:v1.2.0       was v1.1.0
docker.io/envoyproxy/ratelimit:0482748e              was 8fe6ea42
```

The Envoy data plane image did not change. The charts are not mirrored: they
are in this repository.

```bash
./hack/list-images.sh --check          # must print OK, 15 images
oc mirror -c mirror-config.yaml file://mirror --v2
# carry mirror/ across, then
oc mirror -c mirror-config.yaml --from file://mirror docker://REGISTRY.EXAMPLE.COM --v2
oc apply -f working-dir/cluster-resources/idms-oc-mirror.yaml
oc apply -f working-dir/cluster-resources/itms-oc-mirror.yaml
```

The rate limit service that enforces `QuotaPolicy` is not installed by these
charts. Where it is deployed by hand or by another chart, move its image to
`ratelimit:0482748e` in that place too. It ran on both tags against v1.2.0
here.

## The upgrade, step by step

Nothing here needs the internet once the images are mirrored.

### 1. Before

```bash
git pull                                    # this repository, with this change
./hack/update-crds.sh --check               # OK: every crds/ matches the vendored charts
./hack/list-images.sh --check               # OK
helm lint charts/envoy-gateway-openshift charts/envoy-ai-gateway-openshift
oc get clienttrafficpolicy -A               # see "The request size limit" if one targets the Gateway
oc get mcproute -A                          # expected: none. If there are, read the seed section
```

Render twice and compare. It must be identical, or Argo CD will never be
Synced:

```bash
diff <(helm template a charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system) \
     <(helm template a charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system) && echo deterministic
```

### 2a. With Argo CD

Commit and push. Sync `envoy-gateway` first, then `envoy-ai-gateway`. The
CRDs go first inside each Application, at wave -10. Review the diff of the
CRDs before syncing. Add any `values-mirror.yaml` the Applications already
use; nothing else changes.

### 2b. With plain Helm

```bash
./hack/install-crds.sh --dry-run
./hack/install-crds.sh                      # helm upgrade never updates crds/

helm upgrade envoy-gateway charts/envoy-gateway-openshift \
  -n envoy-gateway-system --wait --timeout 6m
helm upgrade envoy-ai-gateway charts/envoy-ai-gateway-openshift \
  -n envoy-ai-gateway-system --wait --timeout 5m

# Envoy Gateway must reconnect to the AI Gateway extension server
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
oc rollout status  -n envoy-gateway-system deployment/envoy-gateway
```

Add `-f charts/<chart>/values-mirror.yaml` to both `helm upgrade` commands
if the install used it. Helm does not remember `-f` files.

The proxy pods are replaced once, when the extproc sidecar image changes.
With one proxy replica that is a short interruption; with two or more and a
`PodDisruptionBudget` it is not.

### 3. After

```bash
for ns in envoy-gateway-system envoy-ai-gateway-system; do
  oc get pods -n $ns -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc,IMAGES:.spec.containers[*].image'
done
# expected: gateway:v1.9.2, ai-gateway-controller:v1.2.0, 0 restarts, nonroot-v2

oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[*].spec.initContainers[*].image}{"\n"}'
# expected: ai-gateway-extproc:v1.2.0

oc get gateway -n envoy-ai-gateway-system                       # PROGRAMMED True
oc get clienttrafficpolicy client-buffer-limit -n envoy-ai-gateway-system \
  -o jsonpath='{.status.ancestors[0].conditions[0].type}={.status.ancestors[0].conditions[0].status}{"\n"}'   # Accepted=True
oc logs -n envoy-gateway-system deploy/envoy-gateway --tail=2000 | grep -ciE '"level":"error"|	error	'   # 0
oc get crd gateways.gateway.networking.k8s.io --show-managed-fields \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager} {end}{"\n"}'    # no helm, only the cluster's own managers
oc get co ingress -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'   # Available=True Degraded=False
```

Then send real requests, as in the README's "Proving the data path forwards
traffic": one small, and one with a body above 32 KB, which must not be 413.

## What went wrong on the way

Each of these cost time. None is a problem in the charts as committed.

| What happened | Cause | What to do |
|---|---|---|
| `helm upgrade envoy-ai-gateway` failed: `conflict with "kubectl-set" using apps/v1: .spec.template.spec.containers[name="ai-gateway"].image` | Somebody had changed the controller image with `oc set image`. Helm 4 applies server-side and does not take a field another manager owns | Add `--force-conflicts` to that `helm upgrade`. It only happens on a cluster where the image was set by hand |
| `helm upgrade` refused an object that already existed | A `ClientTrafficPolicy` named `client-buffer-limit` had been created by hand | Delete the hand-made one first, or give the chart's another `name` |
| Two renders of the AI Gateway chart differed | The MCP seed, see above | Already fixed by the override |
| `./hack/list-images.sh --check` failed after the bump | Envoy Gateway v1.9.2 names a newer rate limit image | Already fixed in `mirror-config.yaml` |
| A proxy pod with a self-built extproc went to `Init:CrashLoopBackOff`: `config version mismatch: expected "dev", got "v1.2.0"` | The controller writes its version into the filter config and the extproc refuses another one. A binary built without the right `-ldflags` calls itself `dev` | Only for self-built images. See the build command below: the version must have the form `v1.2.0-0-g<commit>` |
| The same pod kept crashing after the image was rebuilt | The node had the first build cached under the same tag, and the pull policy is `IfNotPresent` | Push a rebuilt image under a new tag, or refer to it by digest |

## What was tested

All on the lab cluster, through the gateway, with a stand-in for the model
server.

| Check | Result on stock v1.2.0 |
|---|---|
| Chat request, small, 47 KB and 1 MB | 200 |
| The objects aigw-ui had written as `v1alpha1` under v1.1.0 | still accepted, nothing had to change |
| aigw-ui self-test on a model counted in tokens and on a priced model | passed, 10 of 13 steps, the other 3 not applicable to one site |
| A priced model | counted at the cost its prices give, and refused at the limit (part of the self-test) |
| `/anthropic/v1/messages`, plain and streamed | 200, answered in Anthropic's format, counted |
| A model with an entry route over two sites | **nothing counted**: 20 requests answered against a limit of 60 tokens, counter 0. Same as v1.1.0 |
| A cached prompt on `/anthropic/v1/messages` | **charged in full**: the cached count is dropped. Same as v1.1.0 |

The last two are what the patches are for.

### Performance

One proxy pod, a model server that answers at once with a fixed body, load
from a pod in the cluster. "Added" is the time through the gateway minus the
time straight to the model server, one request at a time.

| | v1.1.0 | v1.2.0 | v1.2.0 with both patches |
|---|---|---|---|
| Added per request, 2 KB prompt, no quota | 2.6 ms | 2.3 ms | 2.2 ms |
| Added per request, 2 KB prompt, quota in tokens | 4.0 ms | 3.9 ms | 3.9 ms |
| Added per request, 2 KB prompt, quota in dollars | 4.1 ms | 4.2 ms | 4.2 ms |
| Added per request, 100 KB prompt, quota in dollars | 6.6 ms | 6.6 ms | 6.1 ms |
| Added per request, 1 MB prompt, quota in dollars | 16 ms | 17 ms | 17 ms |
| Requests a second, 32 connections, no quota | 9,350 | 9,370 | 9,480 |
| Requests a second, 32 connections, quota in tokens | 5,630 | 5,420 | 5,110 |
| Requests a second, 32 connections, quota in dollars | 4,850 | 5,410 | 5,380 |

What that says:

- The upgrade neither slows nor speeds the gateway beyond the noise of the
  measurement, which is about 10% between runs.
- A quota costs about 1.5 ms a request and about 40% of the throughput of
  one proxy pod: two calls to the rate limit service, one before and one
  after the request.
- Dollars cost the same as tokens. The price arithmetic is not measurable.
- At full load one proxy pod used about 6 CPU for Envoy, 3 to 5 for the
  extproc sidecar and 3 to 4 for the rate limit service. The chart's
  default request of 100m CPU and limit of 1 GiB memory is for a test; size
  a production proxy for its request rate, and add replicas rather than
  only CPU.
- Against a model's own time to answer, seconds, the gateway's 4 ms does
  not matter. The body size does: 1 MB takes 16 ms more, and a multi-site
  entry route buffers it at the entry gateway and again at the serving one.

## The three patches

All are against the tag `v1.2.0` of `theagentrouter/agent-router`, in
`patches/agent-router-v1.2.0/`. None is needed for the upgrade itself.

| Patch | What is wrong without it | Upstream |
|---|---|---|
| `0001-extensionserver-apply-QuotaPolicy-to-per-backend-clu.patch` | A model whose route has weighted backends, which is every entry route over two or more sites, gets no quota at all: nothing is counted and nobody is refused | Proposed as agent-router pull request #2833 |
| `0002-translator-keep-cached-tokens-on-Anthropic-requests-.patch` | On `/anthropic/v1/messages` to an OpenAI-style backend such as vLLM, the cached token count is dropped. A cached prompt is charged in full and the client sees no cache read | Not proposed yet |
| `0003-fix-add-one-InferencePool-ext-proc-filter-per-pool-n.patch` | A model behind an `InferencePool` gets its scheduler filter once per route match that uses the pool, not once. On the lab that was 16 times, so the proxy asked the scheduler up to 16 times for one request. With the scheduler's defaults that is wasted work. With flow control and `concurrency-detector` every request waits out its TTL and gets 429, because the request itself takes all the slots | Merged upstream after v1.2.0 as agent-router pull request #2595. A backport, not our change |

Tested on the lab with both applied:

| Check | Stock v1.2.0 | Patched |
|---|---|---|
| Two sites, limit 60 tokens an hour, 20 requests | 20 answered, counter 0 | 9 answered, 11 refused with 429, counter 74 |
| A tenant without a quota on that model | not run | refused: the model's pool is 1 token |
| aigw-ui self-test on the two-site model | not run | passed, 11 of 13 steps |
| Best-effort with a limit of 30 tokens | not possible, nothing is counted | moved to best-effort at 93% of the budget, served with the class `best-effort`, taken off at the limit, then 429 |
| The same 100-token prompt twice on `/anthropic/v1/messages`, priced model | 1041 and 1041 credits | 1041 and 177 credits; the answer shows `cache_read_input_tokens: 96` |

Tested on the lab with the third patch as well (KServe 0.21, endpoint
picker v0.10.0, a model limited to two requests at a time):

| Check | Without 0003 | With 0003 |
|---|---|---|
| Scheduler filters for the model in the proxy's listener | 16 | 1 |
| One request to an idle model, flow control with `concurrency-detector` | 429 after 60 s | answered |
| 8 standard requests, then 6 `best-effort` at 3 s, then 6 standard at 5 s | best-effort answered before the later standard ones | all 14 standard answered first; best-effort answered last or 429 at its TTL |

One thing seen once: a single request got 500 in the seconds in which the
hub created the best-effort route for a tenant.

### Building the patched images

This needs the internet, or a Go module proxy, once: for `go build`. The
result is two images to carry across with the others.

```bash
git clone https://github.com/theagentrouter/agent-router && cd agent-router
git checkout -b site-v1.2.0 v1.2.0
git am /path/to/patches/agent-router-v1.2.0/*.patch
go test ./internal/extensionserver/ ./internal/translator/

# The version must parse as a release: "<tag>-0-g<commit>". Anything else
# makes the binary call itself "dev", and an extproc that is "dev" refuses the
# config of a controller that is "v1.2.0", and the other way round. Build
# both from the same commit with the same string.
V="-X github.com/envoyproxy/ai-gateway/internal/version.version=v1.2.0-0-g$(git rev-parse --short=8 HEAD)"
for c in controller extproc; do
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w $V" -o out/$c ./cmd/$c
done
```

Each binary goes into an image of this shape, which is what upstream's
does:

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --chmod=755 app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

Point the chart at them. Use a tag that has never been used for another
build:

```bash
helm upgrade envoy-ai-gateway charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system --wait \
  --set ai-gateway.controller.image.repository=REGISTRY.EXAMPLE.COM/envoyproxy/ai-gateway-controller \
  --set ai-gateway.controller.image.tag=v1.2.0-site1 \
  --set ai-gateway.extProc.image.repository=REGISTRY.EXAMPLE.COM/envoyproxy/ai-gateway-extproc \
  --set ai-gateway.extProc.image.tag=v1.2.0-site1
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
oc rollout restart -n envoy-gateway-system deployment -l app.kubernetes.io/component=proxy
```

Under Argo CD the four values go into the Application's values instead.
The quota fix is in the controller, the cached-token fix in the extproc.
Patch 0001 alone needs only the controller image; the extproc can stay
upstream's, because both then call themselves `v1.2.0`.

Remove the patched images when a release contains the fixes.

## aigw-ui

The hub that writes quotas and routes, `roiblum1/aigw-ui`:

- **Up to 0.11.0** writes `aigateway.envoyproxy.io/v1alpha1` objects. They
  work unchanged on v1.2.0. The API server answers each write with a
  deprecation warning.
- **From 0.12.0** it writes `AIGatewayRoute` and `AIServiceBackend` as
  `v1beta1`, which v1.1.0 and v1.2.0 both serve, and `QuotaPolicy` as
  `v1alpha1`, its only version. It also accepts a key in the `x-api-key`
  header, which Anthropic clients send by default; before that only
  `Authorization: Bearer` worked.

No order is required between upgrading the gateway and the hub.

## Rollback

```bash
helm rollback envoy-ai-gateway -n envoy-ai-gateway-system
helm rollback envoy-gateway    -n envoy-gateway-system
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
```

`helm rollback` leaves the CRDs at the new version. The v1.2.0 CRDs only add
optional fields, so v1.1.0 runs against them. To put the old CRDs back as
well:

```bash
git checkout <commit before this change> -- 'charts/*/crds' hack/charts
./hack/install-crds.sh
```

The `ClientTrafficPolicy` goes with the rollback of the AI Gateway chart, and
requests above 32 KB are refused again. Keep it by applying it by hand if
that matters. Under Argo CD, revert the commit and sync.

## Not done

- Gateway API stays at the cluster's v1.4.1. Envoy Gateway v1.9.2 and Agent
  Router v1.2.0 are built against v1.6.1 and ran against v1.4.1 here.
- The InferencePool CRDs stay at v1.5.0, KServe's. v1.2.0 is built against
  v1.6.2. No `InferencePool` existed on the lab, so a model served through
  an `InferencePool` was not run after this upgrade. Run the README's
  "Proving the KServe data path" on a cluster that has one.
- No real vLLM was behind the gateway. The cached-token results come from a
  stand-in that reports a repeated prompt as cached.
- Argo CD was not used. The render is deterministic, which is the property
  Argo CD needs; a sync itself was not run.
