# A fleet site and a model

Written and tested on the lab (OpenShift 4.22, KServe 0.21, Envoy Gateway
1.9.2, Envoy AI Gateway 1.2.0 with the patches in `patches/`) on 2026-10-11.
This page covers two charts: what `charts/envoy-ai-gateway-openshift` adds so
that aigw-ui can count, price and limit a model, and `charts/llm-model`,
which deploys one model. Both were developed outside this repo and moved in
unchanged, except that the rate limit service now has a default Redis
address so the chart renders with no overrides.

## charts/envoy-ai-gateway-openshift

| Object | Why |
|---|---|
| `Deployment` + `Service` `envoy-ai-gateway-ratelimit` (Envoy Gateway namespace) | Enforces `QuotaPolicy`. The upstream chart only points the controller at it and does not deploy it |
| `Secret` `envoy-ai-gateway-ratelimit-redis` | `REDIS_URL` and `REDIS_AUTH` for that service. Use `rateLimit.redis.existingSecret` under Argo CD |

Already in the repo's chart since the 1.2.0 upgrade, check that yours has them:

- `ClientTrafficPolicy` with `connection.bufferLimit: 50Mi`. Without it any
  prompt over 32 KB gets 413.
- `ai-gateway.controller.mcp.sessionEncryption.seed` pinned. The upstream
  default is random on every render, which Argo CD sees as a change forever.

    helm upgrade --install envoy-ai-gateway charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system \
      --set rateLimit.redis.url=<redis host>:6379

Tested: the rate limit service of this chart started on the lab under a
test name and connected to Redis and the controller. The whole chart was
rendered and linted, not installed over the lab's running release.

## charts/llm-model

One model. It creates the gateway side of a model and, optionally, the
`LLMInferenceService`. It does not contain your storage and cache parts
(PVs, PVCs, the node DaemonSet, the S3 download Job, LMCacheEngine,
PrometheusRule, roles, StorageClass): those were not available to copy.
Set `model.create=false` to use only the gateway objects next to your own
`LLMInferenceService`.

| Object | Why |
|---|---|
| `LLMInferenceService` | The model, with `--enable-prompt-tokens-details --enable-force-include-usage` so cached tokens and streamed usage are reported |
| `Backend` | Where the gateway sends: to KServe's route through the scheduler (default), or straight to the vLLM Service |
| `AIServiceBackend` | What a `QuotaPolicy` targets. Removes `kv_transfer_params` from requests |
| `AIGatewayRoute` | Matches the model name. aigw-ui discovers the model from it |
| `Secret` (internal key) | See below |
| `SecurityPolicy` on `<model>-kserve-route` | See below |
| `BackendSecurityPolicy` | Lets the gateway's second hop use KServe's route |

### The hole this chart closes

KServe attaches its own `HTTPRoute` for the model to the same Gateway. On
the lab, a tenant with a valid key called

    POST /<namespace>/<model>/v1/chat/completions

and was answered with nothing counted against its budget. The same worked
on `/v1/chat/completions` with the header `X-Gateway-Model-Name`. The
`SecurityPolicy` here makes that route accept only an internal key, which
the gateway presents on its second hop. With the chart installed both calls
got 401 and the normal URL kept working.

### Tested on the lab

With vLLM 0.29 on CPU and Qwen2.5-0.5B, `route.through=scheduler`:

- chat, streamed chat and `/anthropic/v1/messages` answered through the
  scheduler, each charged exactly what vLLM reported;
- a repeated 555-token prompt: 512 tokens cached, charged $0.0126 against
  $0.0587 the first time;
- a forged `kv_transfer_params` was charged in full;
- a spent daily budget got 429;
- aigw-ui's self-test passed (needs aigw-ui 0.12.1).

Not tested: a GPU image, LMCache.

    helm upgrade --install glm charts/llm-model -n <model namespace> \
      --set model.name=<name> --set model.uri=<uri> --set internalKey.value=<random>

## Wider checks and benchmark, 2026-10-11

Run on the lab against the chart's model (vLLM 0.29 on CPU, Qwen2.5-0.5B).

Correct:

- chat, completions, streamed with and without `stream_options`: each
  charged exactly what vLLM reported;
- two tenants, 12 parallel requests each: each counter moved only by its
  own tenant's use;
- 154,130 requests under full load on an instant-answer backend: every one
  charged exactly once;
- invalid body, unknown model, wrong key: not charged. A prompt longer than
  the model's context: refused by vLLM, charged 1 credit ($0.00001);
- six of KServe's own paths with a tenant key: all 401;
- usage history and the tenant's own page equal the counter;
- two replicas: 15 of 15 repeated prompts hit the cache through the
  scheduler, 11 of 15 when the gateway sends straight to the Service.

To know:

- With the rate limit service down, requests are answered and not charged
  (`quotaRateLimitFailureModeDeny: false`, the upstream default).
- A stream the client drops is charged for what was generated until then.
- The class `best-effort` has no effect with KServe 0.21's default
  scheduler settings: with a queue of up to 28 waiting requests the
  scheduler refused nobody and both classes waited the same way. It does
  with `model.flowControl.enabled=true` and a gateway that has
  agent-router#2595. See "A cluster as a fleet site" below.

Cost of the gateway, instant-answer backend, one proxy pod:

| | One hop (`route.through=service`) | Two hops (`scheduler`, without the scheduler's own call) |
|---|---|---|
| Added per request, 2 KB prompt | 4.2 ms | 5.7 ms |
| Added per request, 100 KB prompt | 6.6 ms | 8.0 ms |
| Requests a second, 32 connections | 5,316 | 4,355 |

Not measured: the scheduler's own cost per request, and time to first token
(the CPU model answers one token in 0.2 to 1.7 s, which hides milliseconds).

## A cluster as a fleet site, 2026-10-11

Both charts can now make a cluster a serving site of an aigw-ui fleet, as
`AGENT_ENVOY_AI.md` and `AGENT_MODEL.md` describe it: a client enters at any
site, that site checks the key and the budget, and forwards the request over
mutual TLS to the site that serves the model. The fleet parts are off by
default. Two things are on for every cluster: the client policy now removes
the headers a client must not set and has an idle timeout of 3600s.

### charts/envoy-ai-gateway-openshift

| Value | Adds |
|---|---|
| `gateway.peers.enabled` (needs `gateway.site`, `gateway.peers.serverName`) | Listener `peers` on 8443 that only namespaces with `aigw-ui.io/serving=true` can attach to. Issuer `llm-peer-issuer` over the fleet CA Secret, certificates `llm-peer-server` and `llm-peer-client`, ConfigMap `llm-peer-ca` (from `gateway.peers.caBundle`). `ClientTrafficPolicy` `peers`: a client certificate of the fleet CA is required, the request ID of the entry is kept, `x-llm-served-by: <site>` on every answer |
| `gateway.clientTrafficPolicy.removeRequestHeaders` (on by default) | The headers a client must not set are removed before the key is checked |
| `gateway.clientTrafficPolicy.idleTimeout` | 3600s, for long streamed answers |
| `gateway.health.enabled` | `GET /healthz/gateway` answers 200 without a key, for a global load balancer |
| `gateway.listener.tls` | TLS on the client listener |
| `gateway.envoyProxy.pdb`, `.shutdown`, `.accessLog` | A disruption budget from 2 replicas up, the drain time, and one JSON log line per request with the request ID, model, tenant key ID, class, session and serving site |

The names are the ones aigw-ui uses by default (`FLEET_PEER_CA_CONFIGMAP`,
`FLEET_PEER_CLIENT_SECRET`). Set the hub's `FLEET_DOMAIN` so that
`peers.llm.<domain>` equals `gateway.peers.serverName`, and on each cluster in
the hub: the client listener's name, "part of the fleet", and the peer host.

Not in the chart: a restricted account for the hub (task T7 of the brief). The
hub is given cluster-admin kubeconfigs; that was decided earlier.

### charts/llm-model

| Value | Adds |
|---|---|
| `peer.enabled` | `AIGatewayRoute <model>-peer` on the peer listener to the model's InferencePool, `HTTPRoute <model>-health` (`/healthz/<model>` straight to vLLM's `/health`), `BackendTrafficPolicy <model>-peer` (shed limit `peer.maxParallelRequests`, 3600s timeout), `BackendTrafficPolicy <model>-health` (retry), the classes `interactive` 10, `standard` 0, `batch` -10 |
| `route.direct=false` | Removes the model's own route, Backend, AIServiceBackend and the internal key. The model is then reachable only through the peer listener |
| `gateway.clientListener` | Pins the direct route and KServe's route to the client listener |
| `model.revision`, `model.capacityPerInstance`, `model.maxModelLen` | The three annotations aigw-ui reads. `maxModelLen` also renders `--max-model-len` |
| `model.scoring.weights` (`prefix`, `queue`, `kvCache`, `noHitLru`), `model.scoring.custom` | The scheduler's weights, 3 : 2 : 2 : 2 as before. Always used with flow control; `custom=true` uses them without it. Tested on the lab with queue 5, with and without flow control: the scheduler started with the new weights and answered. The effect on latency and cache hits is not measured |
| `model.scoring.scorers`, `model.scoring.producers` | Another set of scorers, by plugin type and weight, with the data producers they read. Replaces `weights` when not empty. Written for a config that counts load in the scheduler: `active-request-scorer` 3, `token-load-scorer` 1, `prefix-cache-scorer` 1 with `approx-prefix-cache-producer` and `inflight-load-producer`. Rendered and checked against the endpoint picker v0.10.0 source; not run on a cluster |
| `model.flowControl.negativeBandMaxRequests`, `.enableEviction` | How many requests below priority 0 may wait; above it they get 429 at once |
| `namespace.create` | The Namespace with the label the peer listener asks for |
| `alerts.enabled` | A `PrometheusRule` on the scheduler's queue. Rendered, not tested |

Moving a model without a gap:

1. `peer.enabled=true`, `gateway.clientListener=<listener>`, label the namespace.
2. In aigw-ui turn the model into a fleet model. The model's own route is
   older, so it keeps the traffic until the next step.
3. `route.direct=false`.

### What the briefs say and the lab showed differently

- **KServe's own route has to stay.** Without `router.route` KServe 0.21
  still creates the pool and the scheduler and requests are answered, but the
  LLMInferenceService stays `Ready=False` ("no Gateway controller has accepted
  it yet"): KServe only looks at the gateways of its own route. The chart keeps
  `route: {}` and puts it on the peer listener, where no client reaches it.
- **`best-effort` is not rendered by the model chart.** aigw-ui creates that
  class itself (priority -1) for every model set to best-effort. Two owners of
  one object would fight over it.
- **The scheduler settings are the ones that were proven** (the concurrency
  detector), not the brief's. With the default detector, flow control did not
  put standard before best-effort on this stack.
- **`requestTTL` stays 60s.** With the brief's 5s a standard request that
  waits 5 seconds gets 429 as well, and the entry does not try another site
  for a standard request on 429.
- **The health route needs a retry.** vLLM closes a connection that was idle
  for 5 seconds and the hub checks every 5 seconds. 17 of 109 checks got 503
  (connection closed), and three in a row took the only site out: clients got
  503 "no healthy upstream". With the retry: none in the 45 checks counted
  after it.
- **aigw-ui refused a new quota on a model after step 3**, because no cluster
  had an AIServiceBackend for it any more. Fixed in aigw-ui (branch
  `fleet-model-quota`); the lab hub runs the fix.

### Tested on the lab

One cluster as entry and serving site at once, Envoy Gateway 1.9.2, AI
Gateway 1.2.0 with the three patches, KServe 0.21, the lab hub with
`FLEET_DOMAIN`. The gateway objects were applied from this chart's render
next to the running release, not by upgrading it.

- Client listener: `/healthz/gateway` 200 without a key, `/v1/models` 401.
- Peer listener: refused at TLS without a certificate. With it: health 200,
  chat answered through the scheduler, `x-llm-served-by: lab`, the request ID
  kept. One scheduler filter on the peer listener, none on the client one.
- Through the hub's entry route with a tenant key: answered, charged at the
  entry, served through the peer listener (seen in the proxy log).
- A tenant over its budget on a best-effort model, idle site: answered, and
  counted apart as best-effort use.
- Full site (2 at a time, 8 standard at 0 s, 6 best-effort at 3 s, 6 standard
  at 5 s, `negativeBandMaxRequests=4`): 13 of 14 standard answered. Of the 6
  best-effort, 2 got 429 within a second (`rejected-saturated`) and 4 after
  60 s (`rejected-ttl-expired`). None was served before a standard request.
  One standard request waited 60 s and got 429 too.

Not tested: two sites (the entry's retry to another site), TLS on the client
listener, the disruption budget, drain time and access log (accepted by the
API server in a dry run only), the alerts, more than one proxy pod.

Seen once and not reproduced in two tries: the first five requests of a new
tenant were answered and not counted. Its quota was added seconds before the
model was switched to best-effort.
