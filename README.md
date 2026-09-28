# Envoy AI Gateway + KServe LLMInferenceService on OpenShift

Five Helm charts that install [Envoy Gateway](https://gateway.envoyproxy.io/) v1.9.1,
[Envoy AI Gateway](https://aigateway.envoyproxy.io/) v1.1.0,
[LeaderWorkerSet](https://lws.sigs.k8s.io/) v0.10.0 and
[KServe](https://kserve.github.io/website/) LLMInferenceService v0.21.0 on
OpenShift, packaged so they are safe to run on a **shared** cluster and
mirrorable into a **disconnected** registry.

> **KServe leads the versions.** Every component version here is taken from
> KServe v0.21.0's own `llmisvc-dependency-install.sh`, not from the newest
> release of each project. Two documented exceptions, both forced rather than
> chosen: **Gateway API**, which the cluster owns, and **Envoy Gateway**, whose
> pinned v1.8.1 cannot start on a cluster with standard-channel Gateway API.
> See [Versions](#versions) for the matrix, how to re-derive it, and the
> evidence for the Envoy Gateway exception.

Verified end-to-end on OpenShift 4.22.13 / Kubernetes v1.35.6.

| | |
|---|---|
| `charts/envoy-gateway-openshift` | Envoy Gateway control plane + Envoy data plane |
| `charts/envoy-ai-gateway-openshift` | Envoy AI Gateway control plane + GatewayClass/Gateway/Route |
| `charts/lws-openshift` | LeaderWorkerSet controller — multi-node model serving |
| `charts/kserve-llmisvc-openshift` | KServe LLMInferenceService controller |
| `charts/kserve-runtime-configs-openshift` | The `LLMInferenceServiceConfig` presets models refer to |
| `hack/install-crds.sh` | Installs only the CRDs this stack owns |
| `hack/list-images.sh` | Derives the mirror list from the charts; `--check` fails on drift |
| `hack/list-patches.sh` | Derives every value change from the vendored subcharts |
| `hack/resolve-digest.sh` | Resolves an image digest without pulling |
| `mirror-config.yaml` | `oc mirror` v2 `ImageSetConfiguration` for the whole stack |
| [`PATCHES.md`](PATCHES.md) | Audit report: every change from upstream, and why |
| [`UPGRADE.md`](UPGRADE.md) | Version-bump runbook and checklist |
| [`CLAUDE.md`](CLAUDE.md) | Working notes and invariants for this repo |

Every chart is a thin wrapper around one upstream chart, pulled as a Helm
dependency and vendored **byte-identical** — no upstream template is ever
forked. The combined delta is **8 value overrides across five charts**, plus
three SCC RoleBindings, the Gateway wiring, and not letting Helm own any CRD. Of
upstream's 107 `gateway-helm` settings this repo overrides **two**, `lws` and
`ai-gateway-helm` are overridden **not at all**, and 16 of the 17 shared Envoy
Gateway objects render identical to upstream. See
[how far this is from upstream](#how-far-this-is-from-upstream-measured) and
[every change, and why](#every-change-and-why).

**Upgrading: follow [`UPGRADE.md`](UPGRADE.md).** Bumping the version in
`Chart.yaml` is necessary but not sufficient — two image defaults live in Envoy
Gateway's Go source rather than the chart, `helm upgrade` never touches CRDs,
the AI Gateway extension-hook contract ships outside the chart, and six of the
images are hardcoded inside KServe's presets where no Helm value can reach them.

**Disconnected installs** are the intended target. `mirror-config.yaml` feeds
`oc mirror`, whose `ImageDigestMirrorSet` redirects every pull cluster-wide, so
the charts install unmodified. Nothing in the install path reaches a chart
registry: all five upstream subcharts and all three CRD charts are vendored in
this repository.

---

## Why a wrapper chart is needed

The upstream charts do not install cleanly on OpenShift. Four things have to
change, and all four are fixed here.

### 1. SCC: pods are rejected by `restricted-v2`

The upstream charts hard-code `runAsUser`/`runAsGroup`/`fsGroup` **65532** for
the controller, the certgen Job, the Envoy data-plane pods and the injected
ext_proc sidecar. OpenShift's default `restricted-v2` SCC is `MustRunAsRange`
and only admits UIDs from the namespace's `openshift.io/sa.scc.uid-range`
annotation. Without a fix every pod fails admission:

```
pods "envoy-gateway-certgen-" is forbidden: unable to validate against any
security context constraint:
  provider restricted-v2: .spec.securityContext.fsGroup: Invalid value: [65532]:
    65532 is not an allowed group
  provider restricted-v2: .containers[0].runAsUser: Invalid value: 65532:
    must be in the ranges: [1000960000, 1000969999]
```

The charts bind the built-in **`nonroot-v2`** SCC, which is `MustRunAsNonRoot`:
it admits any non-zero UID while still requiring `drop: ALL`, no privilege
escalation and the `RuntimeDefault` seccomp profile. All four images in this
stack declare a non-root `USER`, so this is sufficient — **`anyuid` and
`privileged` are not needed and must not be used.**

The binding is a namespace-scoped `RoleBinding` onto the `system:openshift:scc:nonroot-v2`
ClusterRole that OpenShift generates for every SCC. It grants nothing outside
its own namespace.

> It is bound to the `system:serviceaccounts:<namespace>` group rather than to
> named accounts because Envoy Gateway generates the data-plane ServiceAccount
> as `envoy-<48-char-hash>`, derived from the owning Gateway's namespace and
> name. That name is not knowable at template time. Set
> `openshift.securityContextConstraints.bindNamespaceServiceAccounts=false` and
> populate `extraServiceAccounts` if you need named subjects, but be aware it
> will not cover the data-plane pods.

### 2. Hook ordering: the SCC binding must exist before certgen runs

Upstream's certgen Job carries `helm.sh/hook: pre-install,pre-upgrade`, and Helm
runs **every** pre-install hook before **any** ordinary manifest. A plain
RoleBinding is therefore created too late and certgen fails admission.

The SCC RoleBinding in `envoy-gateway-openshift` is itself a
`pre-install,pre-upgrade` hook with `helm.sh/hook-weight: "-5"`, ordering it
ahead of upstream's certgen RBAC (`-1`) and the certgen Job (`0`).

Consequence: hook resources are not tracked in the release, so `helm uninstall`
leaves that one RoleBinding behind. Deleting the namespace removes it.

### 3. Gateway API CRDs belong to the cluster, not to Helm

**This is the change that matters most on a shared cluster.**

On OpenShift 4.19+ the `cluster-ingress-operator` installs and continuously
reconciles the Gateway API CRDs. On the verified cluster:

```
$ oc get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'
v1.4.1                                   # standard channel, manager=ingress-operator
```

The upstream `crds` sub-subchart (`crds.enabled=true`, the default) carries two
hazards:

* **`crds/`** — Gateway API **v1.6.1 experimental-channel** CRDs, which Helm 4
  server-side-applies over the operator's v1.4.1 standard-channel ones,
  cluster-wide, for every tenant; and
* **`templates/gatewayapi-safe-upgrade-policy.yaml`** — a
  `safe-upgrades.gateway.networking.k8s.io` **ValidatingAdmissionPolicy** whose
  `matchConstraints` are `apiextensions.k8s.io/v1`, `resources: ["*"]`,
  `operations: [CREATE, UPDATE]`, with `failurePolicy: Fail`, and which
  **denies** any Gateway API CRD whose `bundle-version` matches `^v1\.[0-4]`.
  The cluster is on v1.4.1, so this would start rejecting the
  ingress-operator's own reconcile writes.

`envoy-gateway.crds.enabled=false` handles both, because it is a subchart
**condition**: Helm skips the whole subchart, `crds/` and `templates/` alike.
One value, both hazards. `templates/_validate.tpl` fails the render if it is
ever flipped back, or if `crds.gatewayAPI.safeUpgradePolicy.enabled` is turned
on.

`hack/install-crds.sh` then installs **only** `gateway.envoyproxy.io` and
`aigateway.envoyproxy.io`, filtered by API group. It refuses to run if Gateway
API CRDs are missing, and asserts afterwards that it did not become a field
manager on any of them. As a backstop, this chart's `NOTES.txt` does a `lookup`
after every install and prints the cluster's actual Gateway API channel:

```
Verified: Gateway API is v1.4.1 (standard channel), untouched by this release.
```

— or a loud warning if it has flipped to experimental, which would mean the
`crds/` directory got applied after all.

**This is also KServe's own method.** `llmisvc-dependency-install.sh` installs
Envoy Gateway by group-filtering the CRDs and then passing `--skip-crds`:

```bash
helm show crds oci://docker.io/envoyproxy/gateway-helm --version "$EG" \
  | yq 'select(.spec.group == "gateway.envoyproxy.io")' \
  | kubectl apply --server-side --force-conflicts -f -

helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm --version "$EG" \
  -n envoy-gateway-system --create-namespace --skip-crds --wait
```

`hack/install-crds.sh` is that pattern plus offline support and the Gateway-API
assertion. What KServe's script does **not** do is disable the safe-upgrade
policy — `--skip-crds` does not touch `templates/` — so following that script
verbatim on OpenShift installs a cluster-wide `Fail`-policy admission policy
that rejects the ingress operator's writes. That single gap is the strongest
argument for this wrapper chart existing.

#### Why not just `crds.enabled=true`, or `--skip-crds`?

Both were tested. Neither works, and the reason is a **Helm 4 behaviour change**.

Helm's own `--skip-crds` help says CRDs are *"installed if not already
present"* — which would make `crds.enabled=true` safe. That is true of Helm 3,
which did a `Create` and skipped `AlreadyExists`. **Helm 4.3.0 does not.**
Measured with a throwaway CRD in a private API group:

| Operation | Effect on an existing CRD in `crds/` |
|---|---|
| `helm install` | **Overwrites it** via server-side apply (field manager becomes `helm/Apply`) |
| `helm install --skip-crds` | Skips entirely — existing CRD untouched |
| `helm upgrade` | Does nothing — never touches `crds/` |
| `helm uninstall` | Never deletes `crds/` content |

So with `crds.enabled=true`, the *first* `helm install` would server-side-apply
Gateway API **v1.6.1 experimental** over the ingress-operator's v1.4.1 standard
CRDs. `--skip-crds` does protect against that, but it is unusable as the only
defence:

* it is a **CLI flag, not a value**, so the safety of a shared cluster would
  depend on a human remembering it every time;
* it is **all-or-nothing** — it would also skip Envoy Gateway's own 8 CRDs,
  which do need installing, so a separate CRD step is required anyway; and
* it does **not** stop the admission policy, which lives in `templates/`.

And the `crds/` directory cannot be selectively gated: Helm does not template
it, so no value can exclude the Gateway API files while keeping the
`gateway.envoyproxy.io` ones. That is precisely why upstream ships a *separate*
`gateway-crds-helm` chart with the CRDs in `templates/`, where
`crds.gatewayAPI.enabled=false` does work — and why upstream's own docs
recommend it "for clusters with compatible provider-managed Gateway API CRDs".
`hack/install-crds.sh` is that documented path, not a workaround.

Note that `helm upgrade` never touches `crds/` either, so **CRD updates need an
explicit step on every version bump regardless** of which approach is used.
Re-running `hack/install-crds.sh` is that step.

Envoy Gateway v1.9.1 compiles against Gateway API v1.6.1 but probes for each
optional CRD at startup (`tcpRouteCRDExists`, `tlsRouteCRDExists`,
`udpRouteCRDExists`, `listenerSetCRDExists`, …) and disables the watches it
cannot satisfy, so running against the cluster's standard-channel v1.4.1 works.
`TCPRoute`, `TLSRoute`, `UDPRoute` and `XListenerSet` are simply unavailable —
`Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant` and `BackendTLSPolicy` all
are. **That probe is why this chart is pinned to v1.9.1 and not to KServe's
v1.8.1** — see
[Why Envoy Gateway is v1.9.1 and not KServe's v1.8.1](#why-envoy-gateway-is-v191-and-not-kserves-v181).

### 4. Exposing the gateway: LoadBalancer or Route

Both work; pick per cluster.

The **default is `ClusterIP` + an OpenShift Route**, because the cluster this was
verified on has no load-balancer provider:

```bash
$ oc get infrastructure cluster -o jsonpath='{.status.platform}'
None                       # and no MetalLB -> LoadBalancer stays Pending forever
```

On a cluster that **does** have one, use the overlay instead of editing values:

```bash
helm upgrade --install envoy-ai-gateway charts/envoy-ai-gateway-openshift \
  -n envoy-ai-gateway-system --create-namespace \
  -f charts/envoy-ai-gateway-openshift/values.yaml \
  -f charts/envoy-ai-gateway-openshift/values-loadbalancer.yaml
```

That switches the Envoy Service to `LoadBalancer`, sets
`externalTrafficPolicy: Local` to preserve the client source IP, and turns the
Route off. It carries commented-out blocks for MetalLB address pools, AWS NLB
and Azure internal-LB annotations, `loadBalancerSourceRanges`, and moving the
listener to 443. See the table in [Configuration reference](#configuration-reference)
for the full set of `gateway.envoyProxy.service.*` keys.

**The Envoy Service gets a fixed name either way.** Envoy Gateway would
otherwise name it `envoy-<48-char-hash>` (`utils.GetHashedName` over the owning
Gateway's namespace/name), which no template can reference. The chart pins it
through `EnvoyProxy.spec.provider.kubernetes.envoyService.name`, so both the
Route and any external automation have a stable target:

```bash
$ oc get svc -n envoy-gateway-system
NAME               TYPE        CLUSTER-IP       PORT(S)
envoy-ai-gateway   ClusterIP   172.231.90.207   80/TCP     # not envoy-<hash>
```

> Only the **Service** name is pinnable — the generated Deployment, ReplicaSet
> and ServiceAccount keep their hashed names. Select those by label
> (`gateway.envoyproxy.io/owning-gateway-name`) rather than by name.

### 5. KServe's CRDs would be deleted by `helm uninstall`

`kserve-llmisvc-resources` renders four **cluster-scoped** CRDs into
`templates/` when `kserve.llmisvc.createGIECRDs=true`, its default:

```
inferencepools.inference.networking.k8s.io      Gateway API Inference Extension
inferencepools.inference.networking.x-k8s.io
inferenceobjectives.llm-d.ai
inferencemodelrewrites.llm-d.ai
```

`templates/` means Helm owns them, and `helm uninstall` deletes what Helm owns —
taking every `InferencePool` on the cluster with it, including other tenants'.
`charts/kserve-llmisvc-openshift` sets `createGIECRDs: false` and
`hack/install-crds.sh` applies the same four CRDs, rendered from the same chart
version, out of band. The chart refuses to render if the value is flipped back.

The `lws` chart has the mirror-image problem: its three CRDs live in `crds/`,
which `helm upgrade` **never** updates, so a version bump would silently leave
the old schemas in place. Install it with `--skip-crds` and let the script own
them. Forgetting `--skip-crds` at the *same* version is harmless — verified:
server-side apply only conflicts when the incoming content differs, so Helm just
co-owns the identical object. At a *different* version it does conflict.

### 6. The `llminferenceservices` CRD hardcodes the namespace `kserve`

Upstream's CRD chart is not templated at this point:

```yaml
metadata:
  annotations:
    cert-manager.io/inject-ca-from: kserve/llmisvc-serving-cert
spec:
  conversion:
    webhook:
      clientConfig:
        service:
          namespace: kserve            # <- literal, not {{ .Release.Namespace }}
          name: llmisvc-webhook-server-service
```

So the controller must live in `kserve`. Installed anywhere else, the conversion
webhook points at a Service that does not exist and **every read** of an
`LLMInferenceService` fails — an install that looks healthy until first use.
`charts/kserve-llmisvc-openshift` fails the render rather than let that happen
(`openshift.enforceNamespace`).

### 7. The Gateway has to be told about `InferencePool`, and to accept foreign routes

Two things must be true before an `LLMInferenceService` is reachable, and
neither is a default:

* **Envoy Gateway must accept `InferencePool` as a backend kind.** The llmisvc
  controller writes `HTTPRoute`s whose `backendRefs` point at an
  `InferencePool`. Without
  `config.envoyGateway.extensionManager.backendResources`, Envoy Gateway rejects
  the reference with *"Group is invalid, only the core API group,
  multicluster.x-k8s.io and gateway.envoyproxy.io are supported"* and installs a
  **500 direct response** on every matching route.
  `charts/envoy-gateway-openshift/values-inference-pool.yaml` supplies it — a
  re-keyed copy of upstream's own add-on file.
* **The listener must accept routes from the model's namespace.** Those
  `HTTPRoute`s are created in the model's namespace, not the Gateway's, so the
  chart's default `allowedRoutes.namespaces.from: Same` rejects them.
  `charts/envoy-ai-gateway-openshift/values-kserve.yaml` widens it to `All`.

Both are separate overlay files rather than defaults, because both are wrong for
an Envoy-only install: declaring a `backendResource` whose CRD is absent makes
the controller log a failed watch on every reconcile, and widening
`allowedRoutes` for no reason is a needless loosening.

---

## Topology

```
  ┌─ namespace: envoy-ai-gateway-system ──────────────────────────────┐
  │  Deployment/ai-gateway-controller         (AI Gateway)            │
  │  Gateway/envoy-ai-gateway                 (allowedRoutes: All)    │
  │  EnvoyProxy/envoy-ai-gateway              (pins Service name/type)│
  └───────────────────────────────────────────────────────────────────┘
        │ xDS translation hook (gRPC :1063)      ▲ programs
        ▼                                        │
  ┌─ namespace: envoy-gateway-system ─────────────────────────────────┐
  │  Deployment/envoy-gateway                 (Envoy Gateway)         │
  │    + extensionManager.backendResources: InferencePool             │
  │  Deployment/envoy-<hash>                  (Envoy data plane)      │
  │    ├─ envoy               :10080                                  │
  │    ├─ shutdown-manager                                            │
  │    └─ ai-gateway-extproc  (injected by webhook, on AI routes only)│
  │  Service/envoy-ai-gateway  :80 -> :10080   (name pinned)          │
  │  Route/envoy-ai-gateway    edge TLS        (ClusterIP mode only)  │
  └───────────────────────────────────────────────────────────────────┘
        ▲ HTTPRoute parentRef                    ▲ ext_proc (endpoint picker)
        │                                        │
  ┌─ namespace: <model> ──────────────────────────────────────────────┐
  │  LLMInferenceService/<model>                                      │
  │   ├─ HTTPRoute/<model>-kserve-route  -> InferencePool             │
  │   ├─ InferencePool/<model>-inference-pool                         │
  │   ├─ Deployment/<model>-kserve                (vLLM + init fetch) │
  │   ├─ Deployment/<model>-kserve-router-scheduler  (endpoint picker)│
  │   └─ LeaderWorkerSet/<model>-kserve           (multi-node only)   │
  └───────────────────────────────────────────────────────────────────┘
        ▲ reconciled by                          ▲ reconciled by
        │                                        │
  ┌─ namespace: kserve ──────────────┐   ┌─ namespace: lws-system ────┐
  │  Deployment/llmisvc-controller…  │   │  Deployment/lws-controller… │
  │  13x LLMInferenceServiceConfig   │   └────────────────────────────┘
  │  ClusterStorageContainer/default │
  └──────────────────────────────────┘
```

The data plane runs in `envoy-gateway-system`, not next to the Gateway — that is
Envoy Gateway's default (non-`gatewayNamespaceMode`) behaviour. The Service and
the Route are therefore created there too.

In LoadBalancer mode the Route is dropped and `Service/envoy-ai-gateway` carries
the external address, which also surfaces in `Gateway.status.addresses`.

The model's workloads live in the model's own namespace. The two KServe
namespaces hold only controllers and configuration — `kserve` is not negotiable
(see section 6), `lws-system` is just the default.

---

## Install

Requires `helm` 4.x (or 3.8+ for OCI), `oc`/`kubectl`, `python3`, and
cluster-admin for the CRD step. **cert-manager must already be installed** —
KServe's webhook certificate comes from it. On OpenShift use the cert-manager
Operator for Red Hat OpenShift; `hack/install-crds.sh` checks for it.

The subcharts are already vendored, so steps 2–8 need no registry access.

```bash
# 1. OPTIONAL, connected hosts only: refresh the vendored subcharts.
#    Skip this on a disconnected bastion -- charts/*/charts/*.tgz and
#    hack/charts/*.tgz are committed.
for c in charts/*-openshift; do helm dependency update "$c"; done

# 2. CRDs. Never Gateway API -- the script asserts it afterwards.
#    Preview first.
./hack/install-crds.sh --dry-run
./hack/install-crds.sh

# 3. Envoy Gateway, with InferencePool support for KServe.
#    --skip-crds is belt-and-braces: values.yaml already sets
#    crds.enabled=false, which skips the whole crds subchart. Pass it anyway so
#    the command is safe even if that value is ever lost. See section 3.
helm install envoy-gateway charts/envoy-gateway-openshift \
  -n envoy-gateway-system --create-namespace --wait --timeout 6m --skip-crds \
  -f charts/envoy-gateway-openshift/values-inference-pool.yaml

# 4. Envoy AI Gateway (creates the GatewayClass, Gateway and Route),
#    accepting HTTPRoutes from model namespaces
helm install envoy-ai-gateway charts/envoy-ai-gateway-openshift \
  -n envoy-ai-gateway-system --create-namespace --wait --timeout 5m \
  -f charts/envoy-ai-gateway-openshift/values-kserve.yaml

#    On a cluster WITH a load-balancer provider, add the overlay too:
#      -f charts/envoy-ai-gateway-openshift/values-loadbalancer.yaml
#    Confirm first: oc get infrastructure cluster -o jsonpath='{.status.platform}'

# 5. Envoy Gateway must reconnect to the AI Gateway xDS hook
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
oc rollout status  -n envoy-gateway-system deployment/envoy-gateway

# 6. LeaderWorkerSet. --skip-crds because step 2 owns them.
helm install lws charts/lws-openshift \
  -n lws-system --create-namespace --skip-crds --wait --timeout 5m

# 7. KServe LLMInferenceService controller. The namespace MUST be `kserve`.
helm install kserve-llmisvc charts/kserve-llmisvc-openshift \
  -n kserve --create-namespace --wait --timeout 6m

# 8. The LLMInferenceServiceConfig presets. Separate release on purpose --
#    see below.
helm install kserve-runtime-configs charts/kserve-runtime-configs-openshift \
  -n kserve --wait --timeout 3m
```

**Step 5 is required.** Envoy Gateway is configured with an `extensionManager`
pointing at `ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local:1063`,
which does not exist during step 3. It starts fine but cannot finish programming
Gateways until the AI Gateway controller is up and it has reconnected.

**Steps 7 and 8 cannot be one release.** Step 8 creates
`LLMInferenceServiceConfig` custom resources, and step 7 installs a
`ValidatingWebhookConfiguration` for that kind with `failurePolicy: Fail`. Helm
applies every manifest in a release in a single pass and only *then* waits, so
in a combined release the presets would be rejected by a webhook whose Service
has no endpoints yet. Upstream splits them for the same reason; the version pins
in the two `Chart.yaml` files must stay equal.

**`helm upgrade` does not remember `-f` flags, or `--skip-crds`.** Steps 3, 4
and any mirror or LoadBalancer overlay must be repeated on every upgrade of
those releases, or the `extensionManager` block and the widened `allowedRoutes`
silently revert. `--skip-crds` matters less — `crds.enabled=false` already
covers it, and `helm upgrade` never touches `crds/` anyway — but pass it
regardless so the command is identical every time.

### Verify

```bash
# Every pod must show nonroot-v2
for ns in envoy-gateway-system envoy-ai-gateway-system; do
  oc get pods -n $ns -o custom-columns='NAME:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
done

# The shutdown-manager must NOT be gateway-dev:latest
oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'

oc get gateway -n envoy-ai-gateway-system
# NAME               CLASS              ADDRESS          PROGRAMMED
# envoy-ai-gateway   envoy-ai-gateway   172.231.90.207   True

curl -skI "https://$(oc get route envoy-ai-gateway -n envoy-gateway-system -o jsonpath='{.spec.host}')/"
# HTTP/1.1 404 Not Found   <- Envoy answering; no AIGatewayRoute defined yet
```

A 404 is the expected success signal before you define any route: it proves
Route → Service → Envoy is wired. A **503** means the Route or the Service is
misconfigured — see [Troubleshooting](#troubleshooting).

```bash
# LWS and KServe controllers. LWS runs under restricted-v2; llmisvc needs
# nonroot-v2 (it asks for UID 1000).
for ns in lws-system kserve; do
  oc get pods -n $ns -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,SCC:.metadata.annotations.openshift\.io/scc'
done
# lws-controller-manager      true   restricted-v2
# llmisvc-controller-manager  true   nonroot-v2

# KServe's webhook certificate comes from cert-manager; the controller will not
# go Ready without it.
oc get certificate llmisvc-serving-cert -n kserve

# The 13 presets
oc get llminferenceserviceconfig -n kserve --no-headers | wc -l   # 13

# Envoy Gateway must have picked up InferencePool as a backend kind
oc get cm envoy-gateway-config -n envoy-gateway-system \
  -o jsonpath='{.data.envoy-gateway\.yaml}' | grep -A3 backendResources

# The Gateway must accept routes from other namespaces
oc get gateway envoy-ai-gateway -n envoy-ai-gateway-system \
  -o jsonpath='{.spec.listeners[*].allowedRoutes.namespaces.from}{"\n"}'   # All

# And the mirror list must still match the charts
./hack/list-images.sh --check
```

#### Proving the data path forwards traffic

404 only shows Envoy is reachable. To prove xDS programming and upstream
forwarding actually work, apply a throwaway route and backend:

```bash
HOST=$(oc get route envoy-ai-gateway -n envoy-gateway-system -o jsonpath='{.spec.host}')

# A: routing + xDS, no backend required
oc apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: vtest-redirect, namespace: envoy-ai-gateway-system }
spec:
  parentRefs: [ { name: envoy-ai-gateway } ]
  rules:
    - matches: [ { path: { type: PathPrefix, value: /vtest-redirect } } ]
      filters:
        - type: RequestRedirect
          requestRedirect: { scheme: https, hostname: verify.example.com, statusCode: 302 }
EOF

curl -sk -o /dev/null -D- "https://$HOST/vtest-redirect" | grep -iE '^HTTP/|^location:'
# HTTP/1.1 302 Found
# location: https://verify.example.com/vtest-redirect

oc delete httproute vtest-redirect -n envoy-ai-gateway-system
```

Results from the verified run, after also wiring a real httpd backend behind a
`URLRewrite` filter:

| Check | Result |
|---|---|
| `HTTPRoute` accepted | `Accepted=True`, `ResolvedRefs=True` |
| Routing + xDS programming | `302` with the correct `Location` |
| Upstream forwarding | `200`, exact backend body returned |
| Unmatched path isolation | `404` |
| HTTP → HTTPS edge redirect | `302` |
| Envoy Gateway controller log | 114 lines, **0 errors**, 0 restarts |

Note that an ordinary workload in `envoy-ai-gateway-system` still receives
`restricted-v2`, not `nonroot-v2` — granting the SCC does not loosen the default
for anything that does not need it.

#### Proving the KServe data path

`helm install` succeeding proves nothing about routing. Apply a throwaway
`LLMInferenceService` and check the three things that actually break:

```bash
oc create ns vtest-llm
cat <<'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: vtest-llm
  namespace: vtest-llm
spec:
  baseRefs:
    - name: kserve-config-llm-template
  model:
    uri: hf://facebook/opt-125m
    name: facebook/opt-125m
  replicas: 1
  router:
    route: {}
    scheduler: {}
  template:
    containers:
      - name: main
        resources:
          requests: {cpu: 100m, memory: 512Mi}
          limits:   {cpu: "1", memory: 2Gi}
EOF

# 1. The HTTPRoute must be BOTH Accepted and ResolvedRefs on our Gateway.
#    ResolvedRefs=True is the InferencePool backendRef resolving -- that is what
#    proves values-inference-pool.yaml is in effect.
oc get httproute vtest-llm-kserve-route -n vtest-llm \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'
# Accepted=True ResolvedRefs=True

# 2. Envoy must have an ext_proc cluster for the endpoint picker, and NO route
#    left serving a 500 direct response.
POD=$(oc get pods -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway \
  -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n envoy-gateway-system "$POD" 19000:19000 &
sleep 3
curl -s localhost:19000/config_dump | python3 -c '
import sys, json
d = json.load(sys.stdin)
clusters, direct500, routes = [], 0, 0
for c in d["configs"]:
    t = c.get("@type", "")
    if t.endswith("ClustersConfigDump"):
        clusters = [x["cluster"]["name"] for x in c.get("dynamic_active_clusters", [])]
    if t.endswith("RoutesConfigDump"):
        for rc in c.get("dynamic_route_configs", []):
            for vh in rc["route_config"].get("virtual_hosts", []):
                for r in vh.get("routes", []):
                    routes += 1
                    direct500 += r.get("direct_response", {}).get("status") == 500
print("endpointpicker cluster:",
      [n for n in clusters if "endpointpicker" in n] or "MISSING")
print(f"routes={routes} serving-500={direct500}   (500 must be 0)")
'
kill %1

# 3. The endpoint picker must actually see the request.
oc logs -n vtest-llm deploy/vtest-llm-kserve-router-scheduler --tail=5

oc delete ns vtest-llm
```

On a cluster with no GPU and no access to Hugging Face the model pod stays in
its `storage-initializer` init container and the endpoint picker answers **400**
("no ready endpoints"). That is expected and is *not* a wiring failure — steps 1
and 2 above are the wiring test. The endpoint picker also logs
`parsing response: invalid character 'i'` when it tries to JSON-decode its own
plain-text error body; that is an upstream cosmetic bug, not a symptom.

---

## Next step: serve something

Two independent paths share the same Gateway.

**Self-hosted models — `LLMInferenceService`.** This is what the KServe charts
are for. Create one in its own namespace, referring to a preset through
`spec.baseRefs`; the controller creates the `HTTPRoute`, the `InferencePool`,
the vLLM workload and the endpoint picker. The manifest under
[Proving the KServe data path](#proving-the-kserve-data-path) is a working
minimal example. Real serving needs GPU nodes and a reachable model source —
`hf://` requires egress, so in a disconnected cluster point `spec.model.uri` at
S3/PVC or pre-seed a `ClusterStorageContainer`. Multi-node
(tensor/pipeline-parallel) models use `spec.worker`, which is what makes
LeaderWorkerSet a hard dependency.

Reachable at:

```
https://<route-host>/<namespace>/<name>/v1/chat/completions
https://<route-host>/v1/chat/completions                     # also matched
```

**External model providers — `AIGatewayRoute`.** For proxying OpenAI, Bedrock
and friends, create an `AIGatewayRoute` plus an `AIServiceBackend` and
`BackendSecurityPolicy` in `envoy-ai-gateway-system`, per the
[upstream guides](https://aigateway.envoyproxy.io/docs/). Once one attaches to
the Gateway, the AI Gateway mutating webhook injects the `ai-gateway-extproc`
sidecar into the Envoy pod (it is absent until then, which is normal).

---

## Disconnected / mirrored registry

This is the intended deployment target. `mirror-config.yaml` is an
[`oc mirror` v2](https://docs.openshift.com/container-platform/latest/disconnected/mirroring/about-installing-oc-mirror-v2.html)
`ImageSetConfiguration` covering the whole stack: **14 images** plus the
cert-manager operator.

```bash
# On the connected side
oc mirror -c mirror-config.yaml file://mirror --v2

# Move mirror/ across, then on the disconnected side
oc mirror -c mirror-config.yaml --from file://mirror docker://REGISTRY.EXAMPLE.COM --v2

# Apply the mirror maps BEFORE installing any chart
oc apply -f working-dir/cluster-resources/idms-oc-mirror.yaml
oc apply -f working-dir/cluster-resources/itms-oc-mirror.yaml
```

The `ImageDigestMirrorSet` redirects pulls for every pod on the cluster, so the
charts install **completely unmodified** — the `values-mirror.yaml` overlays are
not needed on this path.

### Why the mirror map, and not just chart values

Six of the fourteen images are baked into the `LLMInferenceServiceConfig`
presets that `kserve-runtime-configs` installs:

```
ghcr.io/llm-d/llm-d-cuda:v0.9.0
ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0
ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.10.0
ghcr.io/llm-d/llm-d-latency-predictor-prediction-server:0.9.0
ghcr.io/llm-d/llm-d-latency-predictor-training-server:0.9.0
docker.io/vllm/vllm-openai-cpu:v0.23.0@sha256:89e1fbe8…
```

They are literals in upstream's `files/llmisvcconfigs/resources.yaml`, with no
value hooks — `global.imageRegistry` does not reach them and neither does
anything else. A cluster-level mirror map is the only mechanism that can
redirect them, which is why this repo ships an `ImageSetConfiguration` rather
than a list of images and a set of registry overrides.

### Charts are vendored, not mirrored

`mirror-config.yaml` lists no Helm charts. All five upstream subcharts are
committed under `charts/*/charts/`, and the three CRD-source charts under
`hack/charts/`:

```
hack/charts/gateway-crds-helm-v1.9.1.tgz
hack/charts/ai-gateway-crds-helm-v1.1.0.tgz
hack/charts/kserve-llmisvc-crd-v0.21.0-rc1.tgz
```

`hack/install-crds.sh` reads those in preference to any registry, so the CRD
step runs on a bastion with no egress. It falls back to pulling from upstream
only if a tarball is missing, and says so when it does.

### Keeping the mirror list honest

The list is derived from the charts, not maintained by hand:

```bash
./hack/list-images.sh            # what the charts actually reference
./hack/list-images.sh --check    # exits 1 if mirror-config.yaml has drifted
./hack/list-images.sh --annotate # re-resolve the digests in the comments
```

`--check` compares on `repo:tag`, ignoring digests, because the charts pin some
references by digest while the mirror entries use tags. Mirroring a tag copies
the manifest it points at, so a digest-pinned reference still resolves against
the mirror.

`list-images.sh` also catches the one image that never appears as an `image:`
key: the ext_proc sidecar reaches the manifests only as `--extProcImage=` on the
AI Gateway controller, because the mutating webhook injects it at pod-creation
time.

### If you mirror without a cluster-wide mirror map

Every chart also ships a `values-mirror.yaml` for the case where pulls are not
redirected and the reference itself must name the mirror:

```bash
helm install envoy-gateway charts/envoy-gateway-openshift \
  -n envoy-gateway-system --create-namespace \
  -f charts/envoy-gateway-openshift/values-inference-pool.yaml \
  -f charts/envoy-gateway-openshift/values-mirror.yaml
```

Three image references are **not** rewritten by `global.imageRegistry` and must
be set explicitly — the mirror overlays already do this:

| Image | Where it is set |
|---|---|
| Envoy data plane | `envoy-gateway.global.images.envoyProxy.image` |
| shutdown-manager | `envoy-gateway.config.envoyGateway.provider.kubernetes.shutdownManager.image` |
| ext_proc sidecar | `ai-gateway.extProc.image.repository` |

This path **cannot** cover the six preset images above. If you take it, you
still need an `ImageDigestMirrorSet` for those.

> **`gateway-dev:latest`.** Envoy Gateway's built-in default for the
> shutdown-manager sidecar is `docker.io/envoyproxy/gateway-dev:latest` — a
> mutable dev tag. `charts/envoy-gateway-openshift` overrides it to the release
> image. Installing the upstream chart *without* that override leaves every
> Envoy pod trying to pull `gateway-dev:latest`, which will never resolve on a
> disconnected cluster. Confirm after install:
>
> ```bash
> oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
>   -o jsonpath='{.items[*].spec.containers[*].image}'
> ```

The ext_proc image is pulled by the **data-plane** pods in
`envoy-gateway-system`, so any pull secret for it must exist in that namespace,
not only in `envoy-ai-gateway-system`.

### Model weights are not images

Mirroring the images does not make a model available. `spec.model.uri: hf://…`
needs egress to Hugging Face, which a disconnected cluster does not have. Use
an object store or a PVC reachable from the cluster, and remember that the
fetch runs in the `storage-initializer` init container, using
`docker.io/kserve/storage-initializer` from the `default`
`ClusterStorageContainer`.

## Gateway API version compatibility

Envoy Gateway v1.9.1 builds against **Gateway API v1.6.1**; this cluster serves
**v1.4.1, standard channel**, owned by the ingress-operator. That gap is real but
bounded, and it was measured rather than assumed.

The gap is also *not* what forces the version choice. KServe's pinned Envoy
Gateway v1.8.1 builds against v1.5.1, a nominally smaller gap, and the measured
field diff below is **identical** for both — every v1.6-only addition is in a
kind or field that was already unusable. v1.8.1 is nonetheless unusable here for
a different reason entirely; see
[Why Envoy Gateway is v1.9.1 and not KServe's v1.8.1](#why-envoy-gateway-is-v191-and-not-kserves-v181).

**The wire contract is identical.** Every kind Envoy Gateway uses stores at
`v1` on both sides:

```
gateways            served=v1 v1beta1   stored=v1
gatewayclasses      served=v1 v1beta1   stored=v1
httproutes          served=v1 v1beta1   stored=v1
grpcroutes          served=v1           stored=v1
backendtlspolicies  served=v1           stored=v1
referencegrants     served=v1beta1      stored=v1beta1
```

**Missing kinds are detected and skipped, not fatal.** Envoy Gateway probes for
each optional CRD at startup and disables the watch. From the live controller log:

```
ListenerSet CRD not found, skipping ListenerSet watch
TLSRoute CRD not found, skipping TLSRoute watch
UDPRoute CRD not found, skipping UDPRoute watch
TCPRoute CRD not found, skipping TCPRoute watch
ServiceImport CRD not found, skipping ServiceImport watch
```

So `TCPRoute`, `TLSRoute`, `UDPRoute` and `XListenerSet` are unavailable — all
experimental-channel kinds, none used by AI Gateway.

### Field-level diff, standard v1.4.1 vs standard v1.6.1

| Kind | Fields missing on the cluster | What they are |
|---|---|---|
| `GatewayClass` | **0** | identical |
| `GRPCRoute` | **0** | identical |
| `BackendTLSPolicy` | **0** | identical |
| `ReferenceGrant` | **0** at `v1beta1` | the chart adds a `v1` version the cluster does not serve; the stored version is `v1beta1` on both sides, so nothing Envoy Gateway reads or writes changes |
| `Gateway` | 36 | `spec.allowedListeners.*` and `status.attachedListenerSets` (ListenerSet — CRD not installed anyway), and `spec.tls.frontend.*` / `spec.tls.backend.*` (Gateway-level TLS) |
| `HTTPRoute` | 14 | the native `cors` filter on `spec.rules[].filters[]` and `…backendRefs[].filters[]` |

Reproduce it against the vendored CRD chart:

```bash
helm template x hack/charts/gateway-crds-helm-v1.9.1.tgz \
  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=false
# then diff each kind's openAPIV3Schema property paths against
#   oc get crd <plural>.gateway.networking.k8s.io -o json
```

Only one of those is a real functional difference: **the Gateway API CORS
filter**. And it fails safely — the v1.4.1 `filters[].type` enum is

```
RequestHeaderModifier  ResponseHeaderModifier  RequestMirror
RequestRedirect        URLRewrite              ExtensionRef
```

with no `CORS` member, so an HTTPRoute using it is **rejected at admission with
a clear enum error** rather than silently pruned. Envoy Gateway's own
`SecurityPolicy` (`gateway.envoyproxy.io`, installed at v1.9.1) provides CORS
with the identical field set — `allowOrigins`, `allowMethods`, `allowHeaders`,
`exposeHeaders`, `allowCredentials`, `maxAge` — so there is no capability loss,
just a different CRD.

Nothing Envoy Gateway writes to `Gateway.status` is pruned in practice: the only
v1.6-only status field is `attachedListenerSets`, and the ListenerSet watch is
disabled. The controller shows no reconcile churn — 114 log lines total, zero
errors, zero restarts — which is what a pruning fight would not look like.

Reproduce the diff yourself:

```bash
helm pull oci://docker.io/envoyproxy/gateway-crds-helm --version v1.9.1 --untar
# compare gateway-crds-helm/templates/standard-gatewayapi-crds.yaml
# against: oc get crd <kind>.gateway.networking.k8s.io -o json
```

### When you would need to change this

Install Gateway API v1.6.x yourself only if you need `TCPRoute`/`TLSRoute`/
`UDPRoute`, `XListenerSet`, Gateway-level `spec.tls`, or the native CORS filter.
On OpenShift that is a **cluster-admin decision affecting every tenant**, not a
Helm value — the ingress-operator owns those CRDs and will reconcile them back.
Raise it with the cluster owner rather than working around it.

---

## Configuration reference

Values under `openshift:` and `gateway:` belong to these wrapper charts.
Every other top-level key is the name of the upstream subchart and passes
straight through, so any key from the upstream reference is valid —
[gateway-helm](https://gateway.envoyproxy.io/docs/install/gateway-helm-api/),
`ai-gateway-helm`, `lws`, `kserve-llmisvc-resources`, `kserve-runtime-configs`.

Note the shape: hyphenated keys like `kserve-llmisvc-resources` cannot be
dot-accessed in a Go template, which is why the wrapper templates use
`index .Values "kserve-llmisvc-resources"`.

### `charts/envoy-gateway-openshift`

| Key | Default | Notes |
|---|---|---|
| `openshift.securityContextConstraints.enabled` | `true` | Creates the SCC RoleBinding hook |
| `openshift.securityContextConstraints.name` | `nonroot-v2` | Do not raise this to `anyuid` |
| `openshift.securityContextConstraints.bindNamespaceServiceAccounts` | `true` | Needed for the hashed data-plane SA |
| `envoy-gateway.crds.enabled` | `false` | **Leave false.** See section 3 |
| `envoy-gateway.config.envoyGateway.extensionManager` | set | Remove to run without AI Gateway |
| `envoy-gateway.config.envoyGateway.provider.kubernetes.shutdownManager.image` | `gateway:v1.9.1` | Pins away from `gateway-dev:latest` |

### `charts/envoy-ai-gateway-openshift`

| Key | Default | Notes |
|---|---|---|
| `gateway.enabled` | `true` | Set false to bring your own GatewayClass/Gateway |
| `gateway.envoyProxy.service.name` | `envoy-ai-gateway` | Pins the generated Service name; without it Envoy Gateway uses `envoy-<48-char-hash>` |
| `gateway.envoyProxy.service.type` | `ClusterIP` | `LoadBalancer` where a provider exists — use `values-loadbalancer.yaml` |
| `gateway.envoyProxy.service.annotations` | `{}` | MetalLB pool, AWS NLB, Azure internal LB, … |
| `gateway.envoyProxy.service.loadBalancerIP` | `""` | Request a specific address; only emitted when non-empty |
| `gateway.envoyProxy.service.loadBalancerClass` | `""` | Choose among multiple LB providers |
| `gateway.envoyProxy.service.loadBalancerSourceRanges` | `[]` | Restrict who can reach the LB — recommended when fronting paid model APIs |
| `gateway.envoyProxy.service.externalTrafficPolicy` | `""` | `Local` preserves client IP but only routes to nodes running an Envoy pod |
| `gateway.envoyProxy.service.allocateLoadBalancerNodePorts` | `null` | `false` suppresses NodePorts on providers that do not need them |
| `gateway.envoyProxy.replicas` | `1` | Raise before using `externalTrafficPolicy: Local` |
| `gateway.listener.port` | `80` | Envoy Gateway shifts ports <1024 by +10000, so 80 is served on container port 10080 |
| `gateway.route.create` | `true` | Set false in LoadBalancer mode |
| `gateway.route.targetPort` | `""` (→ `http-80`) | Must name the Service port, **not** the Service port number — see Troubleshooting |
| `gateway.route.tls` | edge / Redirect | Set `enabled: false` for a plain HTTP Route |
| `gateway.envoyGatewayNamespace` | `envoy-gateway-system` | Must match `ai-gateway.envoyGateway.namespace`; the chart fails the render if they drift |
| `ai-gateway.controller.mutatingWebhook.namespaceSelector` | `envoy-gateway-system` | Remove if you enable `gatewayNamespaceMode` |

Overlay files for this chart: `values-loadbalancer.yaml` (LoadBalancer instead
of Route), `values-kserve.yaml` (`allowedRoutes: All`, required for KServe),
`values-mirror.yaml`.

### `charts/lws-openshift`

Overrides **nothing** upstream. The only key that is ours:

| Key | Default | Notes |
|---|---|---|
| `openshift.securityContextConstraints.enabled` | `false` | Not needed — upstream sets `runAsNonRoot: true` with no `runAsUser`, so `restricted-v2` assigns a UID from the namespace range. Verified: the controller runs as 1000980000 under `restricted-v2`. |

Worth knowing before installing: upstream requests `cpu: 1` and `memory: 1Gi`
with no limits, `enableCertManager: false` (LWS issues and rotates its own
webhook certificate), and `enableDisaggregatedSet: false` (a separate API KServe
v0.21.0 does not use). All three are upstream defaults and left alone.

Install with `--skip-crds`; `hack/install-crds.sh` owns the three
`leaderworkerset.x-k8s.io`/`disaggregatedset.x-k8s.io` CRDs.

### `charts/kserve-llmisvc-openshift`

| Key | Default | Notes |
|---|---|---|
| `openshift.securityContextConstraints.enabled` | `true` | Required — the controller asks for UID 1000, which `restricted-v2` rejects |
| `openshift.enforceNamespace` | `kserve` | Fails the render in any other namespace. Set `""` only if upstream starts templating the CRD's webhook namespace |
| `kserve-llmisvc-resources.kserve.llmisvc.createGIECRDs` | `false` | **Leave false.** See section 5; the chart refuses to render if flipped |
| `kserve-llmisvc-resources.kserve.llmisvc.controller.image` | `docker.io/kserve/llmisvc-controller` | Fully qualified so the mirror map applies regardless of node registry search order |
| `kserve-llmisvc-resources.kserve.llmisvc.controller.imagePullPolicy` | `IfNotPresent` | Upstream is `Always`, which makes a restart depend on the registry |
| `kserve-llmisvc-resources.kserve.storage.image` | `docker.io/kserve/storage-initializer` | Same, for the model-fetch init container |
| `kserve-llmisvc-resources.kserve.controller.gateway.ingressGateway.kserveGateway` | `envoy-ai-gateway-system/envoy-ai-gateway` | `<namespace>/<name>` of the Gateway every generated `HTTPRoute` attaches to. A bare name silently resolves to the release namespace, so the chart validates the shape |
| `kserve-llmisvc-resources.kserve.createSharedResources` | `true` | Correct while `kserve-resources` is not installed. Set `false` when adding LLMInferenceService to an existing KServe |

### `charts/kserve-runtime-configs-openshift`

| Key | Default | Notes |
|---|---|---|
| `kserve-runtime-configs.kserve.llmisvcConfigs.enabled` | `true` | Upstream default is `false`; this is the only override and the reason the chart exists |
| `kserve-runtime-configs.kserve.servingruntime.enabled` | `false` | Upstream default. These are the predictive-serving runtimes (sklearn, triton, …) — enabling them adds about a dozen images to mirror |

No pods, no SCC, no OpenShift additions.

---

## Every change, and why

Summary below. **[`PATCHES.md`](PATCHES.md) is the full audit report** — every
override with its upstream value, the added values, the resources this repo
owns, the CRDs moved out of Helm, the install-command deviations, and what a
pure-upstream install would cost. Regenerate its machine-checkable half with
`./hack/list-patches.sh`.

No upstream template, helper or values file is edited, patched or
post-rendered. All five subcharts are vendored byte-identical to a fresh
`helm pull` (verified by sha256 — each digest appears exactly twice). The delta
is **8 value overrides**, 13 added values, five added Kubernetes resource kinds,
and no chart owning a CRD.

```
$ ./hack/list-patches.sh --summary
WRAPPER CHART                       upstream  OVERRIDE  ADDED  restated
------------------------------------------------------------------------
envoy-gateway-openshift                  107         2     12         9
envoy-ai-gateway-openshift                76         0      1         9
lws-openshift                             24         0      0         9
kserve-llmisvc-openshift                 151         5      0         1
kserve-runtime-configs-openshift         158         1      0         1
------------------------------------------------------------------------
TOTAL                                                8     13
```

`restated` keys hold upstream's own value — they exist so the knobs are visible
without extracting the subchart, and deleting them changes nothing. `lws` and
`ai-gateway-helm` are installed with upstream's values verbatim.

### Does KServe's OpenShift guide remove the need for these?

No. [`docs/OPENSHIFT_GUIDE.md`](https://github.com/kserve/kserve/blob/master/docs/OPENSHIFT_GUIDE.md)
is real and current in the repo, but it does not cover this stack:

| | The guide | This repo |
|---|---|---|
| KServe version | **0.14** | 0.21.0 |
| OpenShift | 4.17 | 4.22 |
| API | classic `InferenceService` | `LLMInferenceService` |
| Serving layer | Knative Serving + Istio **or** Kourier | Gateway API + Envoy AI Gateway |
| Install method | `oc apply -f kserve.yaml` (raw manifests) | Helm |
| SCC approach | `oc adm policy add-scc-to-user anyuid -z default -n kserve-demo` | a namespace-scoped `RoleBinding` to `nonroot-v2` |
| Fixing UID rejections | `oc patch deployment … --type=json -p '[{"op":"remove","path":"…/securityContext/runAsUser"}, …]'` | bind an SCC; never patch the pod spec |

So there is no upstream Helm-based OpenShift path to adopt — the guide predates
`LLMInferenceService` entirely and has no Helm content at all. Where it *does*
overlap, its advice is the opposite of what this repo does, and deliberately so:

* **`anyuid`** is the most permissive SCC short of `privileged`. `nonroot-v2`
  admits the same pods while still requiring `drop: ALL`, no privilege
  escalation and `RuntimeDefault` seccomp. On a shared cluster that difference
  matters, so this repo forbids `anyuid` outright (`CLAUDE.md` invariant 3).
* **`oc patch` on a Helm-managed Deployment** makes `kubectl-patch` the field
  manager, and the next `helm upgrade` then fails with a server-side-apply
  conflict. We hit exactly that while building this and recorded it as a
  gotcha. Binding an SCC changes nothing Helm owns.

The guide does show one genuinely useful KServe-native OpenShift affordance,
`serving.kserve.io/storage-initializer-uid`, for pinning the model-fetch
container's UID to the namespace range. It applies to classic
`InferenceService`, not `LLMInferenceService`, so it is not used here — but it
is the shape of the thing that *would* make an SCC binding unnecessary, and is
worth watching for on the llmisvc side.

### Could the changes be smaller? What was tested and rejected

Each of these was attempted, measured, and either adopted or rejected on
evidence:

| Idea | Result |
|---|---|
| Drop the KServe controller's `runAsUser: 1000` so `restricted-v2` assigns a UID — no SCC grant at all | **Does not work.** Helm merges parent values *into* subchart defaults, so a key cannot be removed from a subchart map. Setting it to `null` leaves `runAsUser: 1000`; even restating the whole 7-key `containerSecurityContext` without it leaves `runAsUser: 1000`. Verified both ways. The only alternative is forking the upstream template, which is a bigger delta than one `RoleBinding` |
| Pin the AI Gateway image tags for mirroring | **Rejected as redundant** — upstream's defaults render the identical reference. Removed, taking `ai-gateway-helm` to zero overrides |
| Pin the Envoy Gateway control-plane image | **Rejected as redundant** — upstream's `eg.image` helper already defaults to `gateway:{{ .Chart.Version }}`. Removed earlier for the same reason |
| Use `--skip-crds` instead of `crds.enabled=false` | **Rejected as insufficient** — it does not stop the admission policy in `templates/`, and it is a flag rather than a value. Kept as belt-and-braces alongside the value |
| Follow KServe's Envoy Gateway v1.8.1 pin | **Blocked** — v1.8.1 cannot start without the experimental `ListenerSet` CRD. See [the evidence](#why-envoy-gateway-is-v191-and-not-kserves-v181) |
| Let KServe create its own `kserve-ingress-gateway` (upstream's default) and override nothing | **Possible, not chosen.** It means a second Envoy data plane, Service and Route. One value override points KServe at the Gateway that already exists; set `kserveGateway` back to `kserve/kserve-ingress-gateway` and create that Gateway if you prefer the separation |

### The eight overrides, ranked by how load-bearing they are

| # | Chart | Key | Consequence of *not* setting it |
|---|---|---|---|
| 1 | `gateway-helm` | `crds.enabled=false` | Gateway API v1.6.1 experimental CRDs overwrite the ingress-operator's v1.4.1, **and** a `Fail`-policy admission policy starts rejecting its reconcile writes — cluster-wide, all tenants |
| 2 | `kserve-llmisvc-resources` | `kserve.llmisvc.createGIECRDs=false` | `helm uninstall` deletes four cluster-scoped CRDs and every `InferencePool` on the cluster |
| 3 | `kserve-runtime-configs` | `kserve.llmisvcConfigs.enabled=true` | No presets, so `spec.baseRefs` resolves to nothing and only fully-inline model specs work |
| 4 | `kserve-llmisvc-resources` | `…ingressGateway.kserveGateway` | HTTPRoutes attach to `kserve/kserve-ingress-gateway`, which does not exist, so models are unreachable |
| 5 | `gateway-helm` | `global.images.envoyProxy.image` | The data-plane image is a compiled-in Go default, invisible to `helm template`, so it never reaches the mirror list and pods `ImagePullBackOff` when disconnected |
| 6 | `kserve-llmisvc-resources` | `kserve.llmisvc.controller.image` fully qualified | Works on this cluster (`docker.io` is in `unqualified-search-registries`), but CRI-O tries `registry.access.redhat.com` first, which is unreachable when disconnected. Defensive, not strictly required |
| 7 | `kserve-llmisvc-resources` | `kserve.storage.image` fully qualified | Same as 6, for the model-fetch init container |
| 8 | `kserve-llmisvc-resources` | `kserve.llmisvc.controller.imagePullPolicy=IfNotPresent` | Upstream `Always` makes every pod restart depend on the registry being reachable even though the image is on the node. The most opinionated change here — drop it if you would rather stay byte-identical to upstream |

Plus the `shutdownManager.image` and `extensionApis`/`extensionManager` blocks,
which set keys upstream leaves empty rather than overriding a default: the
first because upstream's compiled-in default is the mutable
`gateway-dev:latest`, the rest because they are upstream AI Gateway's own
published contract.

Numbers 6, 7 and 8 are the three you could remove today with no effect on this
cluster. They exist for the disconnected target, and 8 is a judgement call
rather than a requirement.

---

## Delta from the upstream charts

Nothing upstream is forked — all five upstream charts are Helm dependencies,
vendored byte-identical. Everything below is either a **value override**, an
**added resource**, or a step **moved out of Helm**. Use this as the diff to
re-apply when bumping versions.

Totals: **8 value overrides** across five charts, one added subchart value,
five added Kubernetes resource kinds (`RoleBinding`, `GatewayClass`, `Gateway`,
`EnvoyProxy`, `Route`), and no chart owning a CRD. Every one is itemised with
its justification in [Every change, and why](#every-change-and-why).

| Chart | Upstream leaf values | Overridden |
|---|---|---|
| `gateway-helm` v1.9.1 | 107 | 2 |
| `ai-gateway-helm` v1.1.0 | 76 | **0** (+1 added) |
| `lws` v0.10.0 | 24 | **0** |
| `kserve-llmisvc-resources` v0.21.0-rc1 | 151 | 5 |
| `kserve-runtime-configs` v0.21.0-rc1 | 158 | 1 |

### Value overrides on `gateway-helm` v1.9.1

| Key | Upstream default | Ours | Why |
|---|---|---|---|
| `crds.enabled` | `true` | **`false`** | Upstream subchart ships Gateway API **v1.6.1 experimental** CRDs and a `safe-upgrades` ValidatingAdmissionPolicy that **denies** `bundle-version ^v1\.[0-4]`. OpenShift's ingress-operator owns v1.4.1 standard, so this would overwrite a cluster-wide, multi-tenant resource *and* start rejecting the operator's own reconcile writes. |
| `config.envoyGateway.provider.kubernetes.shutdownManager.image` | *(unset →* `docker.io/envoyproxy/gateway-dev:latest`*)* | `docker.io/envoyproxy/gateway:v1.9.1` | Upstream's compiled-in default is a **mutable `:latest` dev tag** (`api/v1alpha1.DefaultShutdownManagerImage`). Unusable disconnected, unreproducible connected. |
| `global.images.envoyProxy.image` | `""` *(→ compiled-in default)* | pinned by digest | The data-plane image never appears in `helm template` output, so it is invisible to mirroring tooling. |
| `deployment.envoyGateway.image.repository` / `.tag` | `""` *(falls back to chart version)* | explicit `gateway` / `v1.9.1` | Makes `helm template \| grep image:` a complete mirror list. |
| `config.envoyGateway.extensionApis.enableBackend` | `{}` | `true` | Required by AI Gateway — it routes to providers via `Backend`. |
| `config.envoyGateway.extensionApis.enableEnvoyPatchPolicy` | `{}` | `true` | Recommended upstream for compatibility. |
| `config.envoyGateway.extensionManager` | *(unset)* | xDS hook → `ai-gateway-controller...:1063` | AI Gateway registers as an xDS translation hook. Taken from upstream's `manifests/envoy-gateway-values.yaml`. |
| `fullnameOverride` | *(unset)* | `envoy-gateway` | Needed because a Helm dependency **alias** becomes `.Chart.Name` inside the subchart, so `eg.fullname` would emit the alias in every resource name. See the alias note below. |

### Value overrides on `ai-gateway-helm` v1.1.0

**Zero overrides.** One value is *added* where upstream has none:

| Key | Upstream default | Ours | Why |
|---|---|---|---|
| `controller.mutatingWebhook.namespaceSelector` | *(absent)* | `kubernetes.io/metadata.name in [envoy-gateway-system]` | The `MutatingWebhookConfiguration` is cluster-scoped, matches **pod CREATE** and has `failurePolicy: Fail`. Upstream's `objectSelector` already narrows it to envoy-gateway-managed pods; adding a namespaceSelector bounds the blast radius on a shared cluster to the one namespace that has such pods. Remove it if you enable `gatewayNamespaceMode`. |

Two overrides that used to be here were **removed after measuring them**:
`controller.image.tag` and `extProc.image.tag` were pinned to `v1.1.0` for
mirroring, but upstream's `repository` already defaults to
`docker.io/envoyproxy/ai-gateway-{controller,extproc}` and `tag: ""` resolves
to the chart `appVersion`, so the render was byte-identical either way.

```bash
$ helm template x charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system \
    --set ai-gateway.controller.image.tag=null --set ai-gateway.extProc.image.tag=null \
    | grep -oE '(image: |--extProcImage=)\S+' | sort -u
--extProcImage=docker.io/envoyproxy/ai-gateway-extproc:v1.1.0
image: "docker.io/envoyproxy/ai-gateway-controller:v1.1.0"
```

### Value overrides on `lws` v0.10.0

None. The chart installs upstream verbatim; the only addition is an SCC
RoleBinding that is **disabled by default** because it turns out not to be
needed.

### Value overrides on `kserve-llmisvc-resources` v0.21.0-rc1

| Key | Upstream default | Ours | Why |
|---|---|---|---|
| `kserve.llmisvc.createGIECRDs` | `true` | **`false`** | Renders four cluster-scoped CRDs into `templates/`, so `helm uninstall` would delete them and every `InferencePool`/`InferenceObjective` on the cluster. `hack/install-crds.sh` applies the same four, rendered from this same chart version. |
| `kserve.llmisvc.controller.image` | `kserve/llmisvc-controller` | `docker.io/kserve/llmisvc-controller` | An unqualified name is resolved by CRI-O's `unqualified-search-registries`, so a mirror map for `docker.io/kserve/*` only applies if `docker.io` is still in that list on every node. The tag stays derived from `kserve.version`. |
| `kserve.llmisvc.controller.imagePullPolicy` | `Always` | `IfNotPresent` | `Always` makes every pod restart depend on the registry being reachable, even though the image is already on the node — a bad property in a disconnected cluster. |
| `kserve.storage.image` | `kserve/storage-initializer` | `docker.io/kserve/storage-initializer` | Same as above. This is the image in the `default` `ClusterStorageContainer`. |
| `kserve.controller.gateway.ingressGateway.kserveGateway` | `kserve/kserve-ingress-gateway` | `envoy-ai-gateway-system/envoy-ai-gateway` | Points the generated `HTTPRoute`s at the Gateway the AI Gateway chart already created, so model traffic reuses the existing Envoy data plane, Service and Route instead of standing up a second one. Upstream's default assumes you created its own Gateway. |

### Value overrides on `kserve-runtime-configs` v0.21.0-rc1

| Key | Upstream default | Ours | Why |
|---|---|---|---|
| `kserve.llmisvcConfigs.enabled` | `false` | **`true`** | The whole purpose of the chart here: the 13 `LLMInferenceServiceConfig` presets that `spec.baseRefs` resolves against. |

### Resources added (no upstream equivalent)

| Resource | Chart | Why |
|---|---|---|
| `RoleBinding` → `system:openshift:scc:nonroot-v2` | both | Upstream has no SCC support; `restricted-v2` rejects UID 65532. In chart 1 it must be a **`pre-install,pre-upgrade` hook at weight `-5`**, because upstream's certgen Job is itself a pre-install hook and Helm runs all hooks before all ordinary manifests. |
| `GatewayClass`, `Gateway`, `EnvoyProxy` | AI GW | Upstream ships no sample wiring. The `EnvoyProxy` also pins `envoyService.name` (otherwise `envoy-<48-char-hash>`, unreferenceable from a template) and defaults `envoyService.type: ClusterIP` — this cluster reports `platform: None` with no MetalLB, so `LoadBalancer` would hang `Pending`. `values-loadbalancer.yaml` flips it. |
| `Route/envoy-ai-gateway` | AI GW | OpenShift-native ingress in place of a LoadBalancer. `port.targetPort` is the Service **port name** (`http-80`, Envoy Gateway's `irListenerPortName` convention), not the port number — see Troubleshooting. |
| `_validate.tpl` | AI GW | Fails the render if `gateway.envoyGatewayNamespace` and `ai-gateway.envoyGateway.namespace` disagree — otherwise the Route silently points at an endpoint-less Service. |
| `RoleBinding` → `system:openshift:scc:nonroot-v2` | llmisvc | The controller pod asks for UID 1000; `restricted-v2` is `MustRunAsRange` and rejects it. Binding an SCC avoids forking the upstream pod spec. |
| `RoleBinding` → SCC (disabled) | LWS | Present for symmetry and set `enabled: false`. Upstream's `runAsNonRoot: true` with no `runAsUser` passes `restricted-v2` unaided. |
| `_validate.tpl` | llmisvc | Three render-time guards: the namespace must be `kserve` (the CRD hardcodes it), `kserveGateway` must be `<namespace>/<name>`, and `createGIECRDs` must stay `false`. All three are mistakes that produce a healthy-looking install and fail at first use. |
| `values-inference-pool.yaml` | Envoy GW | Re-keyed copy of upstream's `examples/inference-pool/envoy-gateway-values-addon.yaml`. Adds `extensionManager.backendResources: InferencePool`, without which Envoy Gateway serves a 500 on every KServe route. |
| `values-kserve.yaml` | AI GW | Widens the listener to `allowedRoutes.namespaces.from: All`, without which the `HTTPRoute`s KServe creates in model namespaces are rejected. |

### Moved out of Helm

| What | Where it went | Why |
|---|---|---|
| `gateway.envoyproxy.io` + `aigateway.envoyproxy.io` CRDs | `hack/install-crds.sh` (`helm template … \| oc apply --server-side`) | Helm 4 **server-side-applies** `crds/` content on install, so `crds.enabled=true` would overwrite the operator-owned Gateway API CRDs; and Helm does not template `crds/`, so no value can exclude them selectively. Upstream's separate `gateway-crds-helm` chart exists for exactly this and is what the script uses. |
| `serving.kserve.io` CRDs | `hack/install-crds.sh`, from the vendored `kserve-llmisvc-crd` chart | Same reason, plus: this chart is not a dependency of anything here, so nothing else would install it. |
| `inference.networking.k8s.io`, `inference.networking.x-k8s.io`, `llm-d.ai` CRDs | `hack/install-crds.sh`, rendered from `kserve-llmisvc-resources` with `createGIECRDs=true` | Rendering them from the controller's own chart means the CRD schemas always match the controller and there is no separate Gateway API Inference Extension or llm-d-router version to track. |
| `leaderworkerset.x-k8s.io`, `disaggregatedset.x-k8s.io` CRDs | `hack/install-crds.sh`, via `helm show crds` on the vendored chart | They live in the chart's `crds/`, which `helm upgrade` never updates — a version bump would silently keep the old schemas. Install the chart with `--skip-crds`. |
| Chart artifacts themselves | committed under `charts/*/charts/` and `hack/charts/` | So the whole install path, CRDs included, runs with no registry access. |

### How far this is from upstream, measured

Both upstream charts are vendored **byte-identical** (verified by sha256 against
a fresh `helm pull`); nothing is forked.

| `gateway-helm` v1.9.1 | |
|---|---|
| Upstream leaf values | 107 — we override **2**, set 11 absent ones, keep **98%** |
| The 2 overrides | `crds.enabled` → `false`, and `global.images.envoyProxy.image` |
| Objects byte-identical to upstream | **16 of 17** (ignoring the informational `helm.sh/chart` label, which is in no selector) |
| Objects functionally different | **1** — `ConfigMap/envoy-gateway-config`, where every override lands |
| Objects added | 1 — the SCC `RoleBinding` |
| Objects dropped | 23 — 21 CRDs + the 2 `safe-upgrades` admission-policy objects |

For `ai-gateway-helm`: 76 upstream leaf values, **0** overridden, 1 added,
**100%** of upstream's own values kept.

So the whole Envoy Gateway delta is **one ConfigMap, one RoleBinding, and not
installing CRDs**. Everything else is upstream verbatim.

The three charts added later are closer still:

| Chart | Overridden / upstream leaf values | Objects added | Objects dropped |
|---|---|---|---|
| `lws-openshift` | **0** / 24 (100% kept) | 0 (the SCC binding is off) | 3 CRDs |
| `kserve-llmisvc-openshift` | 5 / 151 (97% kept) | 1 — the SCC `RoleBinding` | 4 CRDs |
| `kserve-runtime-configs-openshift` | 1 / 158 (99% kept) | 0 | 0 |

`lws-openshift` needs no alias and no `nameOverride`: the upstream chart is
already named `lws`, which is lowercase and DNS-safe, so `.Chart.Name` — and
with it `app.kubernetes.io/name` inside the immutable Deployment selector —
stays at upstream's value with no help. The same is true of both KServe charts.
That is why only the two Envoy charts carry `nameOverride`/`fullnameOverride`.

Two overrides exist purely to preserve that fidelity rather than to change
behaviour:

* `nameOverride: gateway-helm` — a Helm dependency alias becomes `.Chart.Name`
  inside the subchart, so without this `app.kubernetes.io/name` would be
  `envoy-gateway` rather than upstream's `gateway-helm`. That label is part of
  `Deployment.spec.selector.matchLabels`, which Kubernetes treats as
  **immutable**, so matching upstream keeps an in-place `helm upgrade` from a
  plain `gateway-helm` release possible and makes those 16 objects identical.
* `fullnameOverride: envoy-gateway` — keeps resource names stable
  (`envoy-gateway`, `envoy-gateway-certgen`) regardless of release name.

The control-plane image is deliberately **not** pinned: upstream's `eg.image`
helper already defaults to `docker.io/envoyproxy/gateway:{{ .Chart.Version }}`,
which renders the identical reference. Pinning it produced byte-identical
output, so it was removed.

### Gotchas to re-check on every version bump

The full procedure and checklist live in [`UPGRADE.md`](UPGRADE.md). Two
chart-authoring constraints that are easy to reintroduce and are not obvious
from the upgrade steps:

* **A dependency alias must be lowercase and DNS-safe.** The alias becomes
  `.Chart.Name` inside the subchart, so `alias: envoyGateway` produced
  `envoy-gateway-envoyGateway-certgen` — rejected by the API server, since
  RFC 1123 requires lowercase. Aliases here are `envoy-gateway` and
  `ai-gateway`. `nameOverride`/`fullnameOverride` then hold the labels and
  resource names steady; changing any of the three needs an uninstall, not an
  upgrade.
* **Hook weights.** Upstream's certgen RBAC sits at `-1` and the certgen Job at
  `0`; the SCC binding must stay below both, or certgen fails SCC admission.

### Worth raising upstream

Candidates for issues/PRs against `envoyproxy/gateway` and `envoyproxy/ai-gateway`:

1. **`DefaultShutdownManagerImage` is `gateway-dev:latest`** in a *release*
   artifact. It should default to the release image, or at minimum be surfaced
   as a first-class chart value.
2. **The `crds` subchart is unsafe on provider-managed clusters by default.**
   `crds.enabled=true` + experimental channel + a cluster-wide `Deny` VAP that
   rejects `v1.0`–`v1.4` bundle versions is a footgun on OpenShift 4.19+, GKE
   and any cluster where Gateway API is operator-owned. The VAP's
   `matchConstraints` also uses `resources: ["*"]` with `failurePolicy: Fail`.
   Defaulting `crds.gatewayAPI.enabled=false` when CRDs are already present
   (the chart already does `lookup`-based ownership checks elsewhere) would fix it.
3. **No OpenShift/SCC story.** An `openshift.enabled` preset that either emits
   the SCC RoleBinding *as a correctly-weighted pre-install hook* or drops
   `runAsUser`/`runAsGroup`/`fsGroup` so OpenShift assigns them would remove the
   need for this wrapper chart's most delicate part.
4. **`global.imageRegistry` is incomplete.** It rewrites the control plane,
   certgen and ratelimit images but not the Envoy data plane, the
   shutdown-manager, or AI Gateway's `extProc` — the three that actually need it
   for a disconnected install.
5. **No stable name or alias for the generated Envoy Service**, so a Route or
   Ingress cannot be declared alongside the Gateway.
6. **AI Gateway's pod-mutating webhook has no `namespaceSelector` default**,
   leaving a cluster-scoped `failurePolicy: Fail` webhook broader than it needs
   to be.

---

## Troubleshooting

**Pods `Pending`, events mention "unable to validate against any security context constraint".**
The SCC binding is missing or the pod's ServiceAccount is not covered.
```bash
oc get rolebinding -n envoy-gateway-system | grep scc
oc get pods -n envoy-gateway-system -o custom-columns='NAME:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
```

**Gateway stuck `PROGRAMMED=False`.**
Envoy Gateway cannot reach the AI Gateway extension hook. Confirm the controller
is up, then restart Envoy Gateway (step 5).
```bash
oc logs -n envoy-gateway-system deploy/envoy-gateway | grep -i 'extension\|hook'
```

**Route returns 503 but the Service answers 200 in-cluster.**
The Route's `targetPort` is wrong. An OpenShift Route resolves `targetPort`
against the pods' target port or the Service **port name** — never the Service
port number. `targetPort: 80` gives a router 503 even though
`Service/envoy-ai-gateway` listens on 80. The correct value is the port name
Envoy Gateway generates, `lower("<PROTOCOL>-<port>")`, e.g. `http-80`:

```bash
# what the Service actually offers
oc get svc envoy-ai-gateway -n envoy-gateway-system \
  -o jsonpath='{range .spec.ports[*]}name={.name} port={.port} targetPort={.targetPort}{"\n"}{end}'
# what the Route asks for
oc get route envoy-ai-gateway -n envoy-gateway-system -o jsonpath='{.spec.port}{"\n"}'
# prove the Service itself is healthy, bypassing the router
oc run t --rm -i --restart=Never -n envoy-ai-gateway-system \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://envoy-ai-gateway.envoy-gateway-system.svc:80/
```

**Route returns 503 and the Service has no endpoints.**
No Envoy pod is running or the Gateway is not programmed.
```bash
oc get endpointslices -n envoy-gateway-system -l kubernetes.io/service-name=envoy-ai-gateway
oc get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway
```

**`failed to process ParametersRef for GatewayClass` in the Envoy Gateway log.**
The `GatewayClass` points at an `EnvoyProxy` that does not exist. Benign and
self-healing if it appears only in a short burst while the `EnvoyProxy` is being
recreated — a fresh `helm install` produces none, because Helm creates
`EnvoyProxy` before `GatewayClass`. If it repeats continuously, the
`parametersRef` namespace/name is genuinely wrong:

```bash
oc get gatewayclass envoy-ai-gateway -o jsonpath='{.spec.parametersRef}{"\n"}'
oc get envoyproxy -A
```

**LoadBalancer Service stuck `<pending>`.**
The cluster has no load-balancer provider.
```bash
oc get infrastructure cluster -o jsonpath='{.status.platform}{"\n"}'   # "None" = no LB
oc get ns | grep -i metallb
```
Switch back to the `ClusterIP` + Route default.

**Envoy pods stuck `ImagePullBackOff` on `gateway-dev:latest`.**
The shutdown-manager override is not in effect — see the warning above.

**No `ai-gateway-extproc` container in the Envoy pod.**
Expected until an `AIGatewayRoute` attaches to the Gateway. An
`LLMInferenceService` does not inject it — it uses an `InferencePool` ext_proc
cluster instead, which lives in the Envoy config, not as a sidecar.

**`helm install` of the KServe chart fails with "this chart must be installed in namespace "kserve"".**
Working as intended — see section 6. The CRD's conversion webhook is hardcoded
to that namespace upstream.

**`helm lint` on the KServe chart logs `funcMap fail ... must be installed in namespace "kserve"`.**
`helm lint` renders with namespace `default`. Lint with `-n kserve`:
```bash
helm lint charts/kserve-llmisvc-openshift charts/kserve-runtime-configs-openshift -n kserve
```

**`llmisvc-controller-manager` never goes Ready.**
Almost always cert-manager. The chart creates a self-signed `Issuer` and a
`Certificate` in `kserve`; the pod mounts the resulting Secret.
```bash
oc get certificate,issuer -n kserve
oc get deploy -n cert-manager
```

**`Group is invalid, only the core API group ... are supported` in the Envoy Gateway log, and routes return 500.**
`extensionManager.backendResources` is missing — install the Envoy Gateway chart
with `-f charts/envoy-gateway-openshift/values-inference-pool.yaml`. Remember
that `helm upgrade` does not remember `-f` flags, so an upgrade without it
reverts the setting.
```bash
oc get cm envoy-gateway-config -n envoy-gateway-system \
  -o jsonpath='{.data.envoy-gateway\.yaml}' | grep -A3 backendResources
```
A **short burst** of this message right after an `LLMInferenceService` is
created is benign: the controller writes the `HTTPRoute` before the
`InferencePool` exists, and Envoy Gateway reconverges a second or two later.
Confirm it cleared rather than reading the log alone:
```bash
# must print 0
POD=$(oc get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n envoy-gateway-system "$POD" 19000:19000 & sleep 3
curl -s localhost:19000/config_dump | grep -c '"status": 500'
kill %1
```

**`HTTPRoute` reports `NotAllowedByListeners`.**
The Gateway listener is still `allowedRoutes.namespaces.from: Same` and the
model is in another namespace. Reinstall the AI Gateway chart with
`-f charts/envoy-ai-gateway-openshift/values-kserve.yaml`.

**`LLMInferenceService` stuck with `InferencePoolReady=False / WaitingForGateway`.**
Observed on this stack even when routing is fully working: Envoy Gateway v1.9.1
accepts the `InferencePool` into its resource tree (`added custom backend
resource`) but does not write a `status.parents` entry back, which is what
KServe waits for. Check the wiring directly instead of trusting the condition —
`HTTPRoute` `ResolvedRefs=True` plus an `endpointpicker_*_ext_proc` cluster in
the Envoy config dump means traffic will flow. See
[Proving the KServe data path](#proving-the-kserve-data-path).

**Model pod stuck in `storage-initializer`.**
It is fetching model weights. `hf://` needs egress to Hugging Face; on a
disconnected cluster use an object store or PVC instead.
```bash
oc logs -n <ns> <pod> -c storage-initializer
```

**`LeaderWorkerSet` pods never appear.**
The LWS webhooks have `failurePolicy: Fail`, so the controller must be up.
```bash
oc get deploy lws-controller-manager -n lws-system
oc get mutatingwebhookconfiguration lws-mutating-webhook-configuration \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c   # must be > 1
```
`http: TLS handshake error ... remote error: tls: bad certificate` in the LWS
log is **not** this problem — that is `kube-apiserver-operator` probing port
9443 and rejecting LWS's self-signed CA. Harmless.

---

## Uninstall

Delete any `LLMInferenceService` first — otherwise its workloads, `HTTPRoute`
and `InferencePool` are orphaned when the controller goes.

```bash
oc get llminferenceservice -A          # must be empty before continuing

helm uninstall kserve-runtime-configs -n kserve
helm uninstall kserve-llmisvc         -n kserve
helm uninstall lws                    -n lws-system
helm uninstall envoy-ai-gateway       -n envoy-ai-gateway-system
helm uninstall envoy-gateway          -n envoy-gateway-system
oc delete ns kserve lws-system envoy-ai-gateway-system envoy-gateway-system
```

The cluster-scoped objects these releases own are the `envoy-ai-gateway`
GatewayClass, the `default` `ClusterStorageContainer`, their RBAC and their
webhook configurations. Deleting the namespaces also clears the hook
RoleBindings that `helm uninstall` leaves behind.

CRDs are deliberately **not** removed — deleting a CRD deletes every object of
that type cluster-wide, and on a shared cluster that may not be only yours. To
remove them explicitly, once you are sure nothing else uses them:

```bash
# Review the list first -- this deletes every object of these types cluster-wide.
oc get crd -o name | grep -E 'gateway\.envoyproxy\.io$|aigateway\.envoyproxy\.io$|leaderworkerset\.x-k8s\.io$|disaggregatedset\.x-k8s\.io$|serving\.kserve\.io$|inference\.networking\.(x-)?k8s\.io$|llm-d\.ai$'

# Then, only if that list is what you expect:
oc get crd -o name \
  | grep -E 'gateway\.envoyproxy\.io$|aigateway\.envoyproxy\.io$|leaderworkerset\.x-k8s\.io$|disaggregatedset\.x-k8s\.io$|serving\.kserve\.io$|inference\.networking\.(x-)?k8s\.io$|llm-d\.ai$' \
  | xargs -r oc delete
```

Note the `$` anchors: without them the pattern also matches
`gateways.gateway.networking.k8s.io`, which belongs to the cluster. Be
especially careful with `inferencepools.inference.networking.k8s.io` — it is a
Gateway API Inference Extension CRD that another product on the cluster may also
be using. Check who else has one:

```bash
oc get inferencepool -A
```

Gateway API CRDs are owned by the cluster-ingress-operator and are never touched
by anything in this repository.

---

## Versions

| Component | Version | Source of truth |
|---|---|---|
| Envoy Gateway | v1.9.1 | `charts/envoy-gateway-openshift/Chart.yaml` — **not** KServe's v1.8.1, [and why](#why-envoy-gateway-is-v191-and-not-kserves-v181) |
| Envoy AI Gateway | v1.1.0 | `charts/envoy-ai-gateway-openshift/Chart.yaml` |
| Envoy (data plane) | distroless-v1.39.1 | `api/v1alpha1.DefaultEnvoyProxyImage` in Envoy Gateway v1.9.1 |
| LeaderWorkerSet | v0.10.0 | `charts/lws-openshift/Chart.yaml`; pinned by KServe's `LWS_VERSION` |
| KServe LLMInferenceService | v0.21.0 (charts labelled `v0.21.0-rc1`) | `charts/kserve-llmisvc-openshift/Chart.yaml` |
| vLLM / llm-d presets | llm-d v0.9.0 / router v0.10.0 / vllm-openai-cpu v0.23.0 | Hardcoded in `kserve-runtime-configs` |
| Gateway API | v1.4.1, standard | Provided by OpenShift's cluster-ingress-operator |
| cert-manager | v1.20.3 (Operator v1.20.0) | Pre-existing on the cluster; a prerequisite, not installed here |
| Verified on | OCP 4.22.13 / k8s v1.35.6 | |

### Why Envoy Gateway is v1.9.1 and not KServe's v1.8.1

This is the one component where KServe's pin is not followed, and it is a hard
technical blocker, not a preference.

It is **not** a Helm release-state problem — uninstalling and reinstalling
changes nothing. Proven with a clean-room install of **upstream**
`gateway-helm` v1.8.1: brand-new namespace, brand-new release, no wrapper
chart, no leftover values, `--skip-crds`, and a distinct `controllerName` so it
could not touch the working stack. Result: `exitCode=1`, crash-loop, identical
error.

```
$ oc logs -n envoy-gateway-system deploy/envoy-gateway
error   config-loader  hook error  {"error": "failed to create kubernetes provider:
  failed to create provider Kubernetes: failed to create gatewayapi controller:
  error watching resources: no matches for kind \"ListenerSet\" in version
  \"gateway.networking.k8s.io/v1\""}
Error: failed to create kubernetes provider: ...
```

`ListenerSet` is an **experimental-channel** Gateway API kind. This cluster
serves the **standard** channel, so the CRD does not exist. Envoy Gateway v1.8.1
registers the watch unconditionally in `watchResources()`, before any reconcile
runs and with no config knob to disable it:

```go
// v1.8.1 internal/provider/kubernetes/controller.go:2295
if err := c.Watch(
    source.Kind(mgr.GetCache(), &gwapiv1.ListenerSet{}, ...
```

v1.9.1 added a CRD-existence probe and gates it:

```go
// v1.9.1
listenerSetCRDExists   bool
...
if r.listenerSetCRDExists {
    if err := r.processListenerSets(...)
```

So this is a startup-time API discovery failure in the controller binary. The
full probe lists:

```bash
for v in v1.8.1 v1.9.1; do
  curl -fsSL "https://raw.githubusercontent.com/envoyproxy/gateway/$v/internal/provider/kubernetes/controller.go" \
    | sed -n '/^type gatewayAPIReconciler struct/,/^}/p' | grep -oE '[a-zA-Z]+CRDExists' | sort | tr '\n' ' '
  echo "   <- $v"
done
```

```
backendCRDExists btpCRDExists ctpCRDExists eepCRDExists epCRDExists eppCRDExists
hrfCRDExists serviceImportCRDExists spCRDExists tcpRouteCRDExists udpRouteCRDExists
   <- v1.8.1
backendCRDExists btlsCRDExists btpCRDExists ctpCRDExists eepCRDExists epCRDExists
eppCRDExists extBackendCRDExists grpcRouteCRDExists hrfCRDExists listenerSetCRDExists
serviceImportCRDExists spCRDExists tcpRouteCRDExists tlsRouteCRDExists udpRouteCRDExists
   <- v1.9.1
```

v1.9.1 added `listenerSetCRDExists` (along with `btlsCRDExists` and
`grpcRouteCRDExists`). There is no config knob for it in v1.8.1 — the watch is
registered in `watchResources` with no guard — so the only ways to run v1.8.1
are:

| Option | Verdict |
|---|---|
| Install experimental-channel Gateway API cluster-wide | **No.** Overwrites the ingress-operator's standard-channel CRDs for every tenant — the exact hazard section 3 exists to prevent |
| Install only `listenersets.gateway.networking.k8s.io` from the experimental channel | Additive rather than destructive, so *possible*, but it adds an experimental kind to an API group the ingress-operator owns and continuously reconciles. Not taken here without asking; it is your call, not a default |
| Run Envoy Gateway v1.9.1 | **Taken.** Needs no cluster-scoped change at all |

Compatibility of v1.9.1 with everything KServe needs was checked rather than
assumed:

* `ExtensionManager.BackendResources` — the field
  `values-inference-pool.yaml` sets — exists in **both** v1.8.1 and v1.9.1
  (`api/v1alpha1/envoygateway_types.go`).
* Envoy AI Gateway v1.1.0, which KServe pins, runs against v1.9.1: the Gateway
  reaches `PROGRAMMED=True` and the `InferencePool` ext_proc cluster appears in
  the Envoy config dump. Proven in
  [Proving the KServe data path](#proving-the-kserve-data-path).
* The Gateway API field gap to the cluster's v1.4.1 is **identical** for v1.5.1
  and v1.6.1 — see
  [Field-level diff](#field-level-diff-standard-v141-vs-standard-v161).

**Re-check this on every KServe bump.** If KServe moves to an Envoy Gateway
that has the probe (v1.9.x or later), drop the exception and follow the pin.
`UPGRADE.md` step 1 has the command.

### KServe version labels

KServe's **v0.21.0** GitHub release ships its chart tarballs still named
`…-v0.21.0-rc1.tgz`, and `ghcr.io/kserve/charts` has no `v0.21.0` tag at all —
only `v0.21.0-rc0` and `v0.21.0-rc1`. The `v0.21.0-rc1` artifacts on ghcr.io are
byte-identical to the ones attached to the v0.21.0 release (verified by
extracting both and diffing). So `v0.21.0-rc1` **is** KServe 0.21.0, and that is
what the charts pin. Re-check on the next bump: if upstream starts publishing a
plain `v0.21.x`/`v0.22.0` tag, switch to it.

KServe v0.21.0 also pins its own dependency versions, in
`llmisvc-dependency-install.sh`. Where this repo differs, deliberately:

| KServe v0.21.0 pins | This repo | Status |
|---|---|---|
| `ENVOY_AI_GATEWAY_VERSION=v1.1.0` | v1.1.0 | **follows** |
| `LWS_VERSION=v0.10.0` | v0.10.0 | **follows** — not the newest LWS (v0.11.0 exists) |
| `KSERVE_VERSION=v0.21.0` | v0.21.0-rc1 charts | **follows** (see label note above) |
| `GIE_VERSION=v1.5.0`, `LLMD_ROUTER_VERSION=v0.10.0` | rendered from the `kserve-llmisvc-resources` chart | **follows**, and more tightly: the CRDs come from the controller's own chart, so they cannot drift from it. One version to track instead of three |
| `CERT_MANAGER_VERSION=v1.17.0` via Helm | Operator v1.20.0, pre-existing | **deviates** — the cluster already had it, operator-managed. cert-manager is a prerequisite here, not something these charts install |
| `GATEWAY_API_VERSION=v1.5.1` | v1.4.1 standard | **deviates, forced** — owned by `cluster-ingress-operator`. See [Gateway API version compatibility](#gateway-api-version-compatibility) |
| `ENVOY_GATEWAY_VERSION=v1.8.1` | **v1.9.1** | **deviates, forced** — v1.8.1 crash-loops on standard-channel Gateway API. See [the evidence](#why-envoy-gateway-is-v191-and-not-kserves-v181) |

Re-derive the matrix on every KServe bump — this is the authoritative source,
not the docs site:

```bash
curl -sfL "https://github.com/kserve/kserve/releases/download/v0.21.0/llmisvc-dependency-install.sh" \
  | grep -E '^(CERT_MANAGER|ENVOY_GATEWAY|ENVOY_AI_GATEWAY|LWS|GATEWAY_API|GIE|LLMD_ROUTER|KSERVE)_VERSION='
```

Upstream docs: [Envoy Gateway](https://gateway.envoyproxy.io/docs/install/install-helm/) ·
[Envoy AI Gateway](https://aigateway.envoyproxy.io/docs/getting-started/) ·
[KServe LLMInferenceService](https://kserve.github.io/website/docs/install/llmisvc-install) ·
[LeaderWorkerSet](https://lws.sigs.k8s.io/)
