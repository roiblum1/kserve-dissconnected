# Patch report

Every change this repository makes relative to the upstream charts, and why.

Generated against the vendored subcharts on 2026-09-28. Regenerate the
machine-checkable half at any time:

```bash
./hack/list-patches.sh              # per-chart detail
./hack/list-patches.sh --summary    # the counts table below
```

---

## 0. Scope: no upstream template is forked

All four wrapper charts declare their upstream charts (five in total) as Helm
**dependencies** and vendor them under `charts/` **byte-identical** to a fresh
`helm pull` (verified by sha256). No upstream template, helper or values file
is edited, patched, or post-rendered. Every change is one of:

1. a **value** passed to a subchart,
2. a **resource added** by a template this repo owns — including upstream's
   13 KServe presets, re-rendered from the subchart's own file with a sync
   wave (§4),
3. **CRDs** shipped in a wrapper's `crds/`, generated from the vendored
   upstream CRD charts with two Argo CD annotations added (§5), or
4. a **namespace** the chart must be deployed to.

That is the whole surface. There is no hidden patching.

---

## 1. Value changes, by the numbers

```
WRAPPER CHART                                        upstream  OVERRIDE  ADDED  restated
-----------------------------------------------------------------------------------------
envoy-gateway-openshift                                   107         2     13         9
envoy-ai-gateway-openshift                                 76         1      1        11
lws-openshift                                              24         0      0         9
kserve-llmisvc-openshift [kserve-llmisvc-resources]       151         5      0         1
kserve-llmisvc-openshift [kserve-runtime-configs]         158         0      0         2
-----------------------------------------------------------------------------------------
TOTAL                                                                 8     14
```

Three categories, and the distinction matters when judging risk:

| | Meaning | Risk on a version bump |
|---|---|---|
| **OVERRIDE** | the key exists upstream with a **different** value | Real. If upstream renames or removes it, Helm accepts our value silently and does nothing |
| **ADDED** | the key does **not** exist in upstream's `values.yaml` | Low. These are free-form config blocks (`config.envoyGateway.*`) or upstream-published contracts |
| **restated** | the key exists upstream with the **same** value | None. Present only so the knob is visible without extracting the subchart. Deleting them changes nothing |

**8 overrides** is the number that matters. `lws` and `kserve-runtime-configs`
are installed with upstream's values verbatim; `ai-gateway-helm` has one
override, forced by Argo CD.

---

## 2. The 8 overrides

Ranked by what breaks if you omit them.

### `gateway-helm` v1.9.1 — 2 overrides

| Key | Upstream | Ours |
|---|---|---|
| `crds.enabled` | `true` | **`false`** |

The `crds` sub-subchart ships Gateway API **v1.6.1 experimental-channel** CRDs
in `crds/`, plus a `safe-upgrades.gateway.networking.k8s.io`
ValidatingAdmissionPolicy in `templates/`. On OpenShift 4.19+ the
`cluster-ingress-operator` owns and continuously reconciles the Gateway API
CRDs (this cluster: **v1.4.1, standard**).

*Without it:* the first `helm install` server-side-applies experimental CRDs
over the operator's, cluster-wide, for every tenant — **and** installs an
admission policy whose `matchConstraints` are `apiextensions.k8s.io/v1`,
`resources: ["*"]`, `failurePolicy: Fail`, denying any Gateway API CRD with
`bundle-version` matching `^v1\.[0-4]`. That is the ingress operator's own
reconcile writes.

*Why one value covers both:* `crds.enabled` is a subchart **condition**, so
Helm skips the entire subchart — `crds/` and `templates/` alike.

*Guard:* `charts/envoy-gateway-openshift/templates/_validate.tpl` fails the
render if this is `true`, or if `crds.gatewayAPI.safeUpgradePolicy.enabled` is.
`NOTES.txt` does a post-install `lookup` that prints the cluster's actual
Gateway API channel. (`--skip-crds` is no longer passed: the wrapper's own
`crds/` now carries the `gateway.envoyproxy.io` CRDs, and the flag would skip
them too.)

*Verify:* `helm template … --include-crds | grep -cE '^  group: gateway\.networking\.k8s\.io$'` → `0`

| Key | Upstream | Ours |
|---|---|---|
| `global.images.envoyProxy.image` | `""` | `docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c1…` |

Empty means "use the compiled-in Go default"
(`api/v1alpha1.DefaultEnvoyProxyImage`), which never appears in
`helm template` output.

*Without it:* the Envoy data-plane image is invisible to any mirroring tool, so
it never reaches `mirror-config.yaml` and every Envoy pod hits
`ImagePullBackOff` on a disconnected cluster.

*Verify:* `./hack/list-images.sh` includes the data-plane image.

### `kserve-llmisvc-resources` v0.21.0-rc1 — 5 overrides

| Key | Upstream | Ours | Why |
|---|---|---|---|
| `kserve.llmisvc.createGIECRDs` | `true` | **`false`** | Renders 4 cluster-scoped CRDs into `templates/` (`inferencepools` ×2, `inferenceobjectives`, `inferencemodelrewrites`). Helm owns `templates/`, so **`helm uninstall` deletes them** — and every `InferencePool` on the cluster, including other tenants'. `hack/update-crds.sh` renders the same four, from this same chart version, into static `crds/` files with `Prune=false,Delete=false` (§5). Guarded by `templates/_validate.tpl`. |
| `kserve.controller.gateway.ingressGateway.kserveGateway` | `kserve/kserve-ingress-gateway` | `envoy-ai-gateway-system/envoy-ai-gateway` | The `parentRef` of every `HTTPRoute` the controller creates. Upstream's default names a Gateway that KServe's own installer creates; we point at the one the AI Gateway chart already made, so model traffic reuses the existing Envoy data plane, Service and Route. *Without it:* routes attach to a nonexistent Gateway and models are unreachable. **Alternative:** leave upstream's value and create `kserve/kserve-ingress-gateway` yourself — costs a second data plane and Route. |
| `kserve.llmisvc.controller.image` | `kserve/llmisvc-controller` | `docker.io/kserve/llmisvc-controller` | Unqualified names are resolved by CRI-O's `unqualified-search-registries`, which on this cluster is `['registry.access.redhat.com', 'docker.io']`. It *works* here — but CRI-O tries `registry.access.redhat.com` **first**, which is unreachable when disconnected. Naming the registry removes the dependency on node config. Tag still derives from `kserve.version`. **Defensive, not strictly required.** |
| `kserve.storage.image` | `kserve/storage-initializer` | `docker.io/kserve/storage-initializer` | Same reasoning; this is the image in the `default` `ClusterStorageContainer` that fetches model weights. **Defensive, not strictly required.** |
| `kserve.llmisvc.controller.imagePullPolicy` | `Always` | `IfNotPresent` | `Always` makes every pod restart depend on the registry being reachable, even though the image is already on the node. **The most opinionated change in this repo** — drop it if you would rather stay byte-identical to upstream. |

### `ai-gateway-helm` v1.1.0 — 1 override

| Key | Upstream | Ours |
|---|---|---|
| `controller.mutatingWebhook.certManager.enable` | `false` | **`true`** |

Upstream mints the webhook certificate inside the template, guarded by a
`lookup` of the existing Secret. Argo CD renders in the repo-server with no
cluster connection, so `lookup` is always nil and **every render** generates a
new CA and key (measured: two consecutive renders differ only in that Secret).

*Without it, under Argo CD:* the Application is permanently OutOfSync and, with
selfHeal, rewrites the webhook keypair on every sync. With cert-manager the
Secret leaves the render, a `Certificate` and a selfSigned `Issuer` replace it,
and two renders are byte-identical. cert-manager is already required for
KServe, so no new dependency. Plain Helm does not need it but is not harmed.

### `kserve-runtime-configs` v0.21.0-rc1 and `lws` v0.10.0 — zero overrides

Installed with upstream's values verbatim. For `kserve-runtime-configs` that
includes `kserve.llmisvcConfigs.enabled: false` — the presets are rendered by
the wrapper instead (§4) — and `kserve.servingruntime.enabled: false`, the
predictive-serving runtimes (sklearn, triton, tensorflow …) that
`LLMInferenceService` does not use and which would add roughly a dozen images
to mirror.

---

## 3. The 14 added values

Keys that do not exist in upstream's `values.yaml`, so nothing is being
overridden.

### `gateway-helm` — 13

**One is upstream AI Gateway's own InferencePool add-on**, re-keyed from
`https://raw.githubusercontent.com/envoyproxy/ai-gateway/v1.1.0/examples/inference-pool/envoy-gateway-values-addon.yaml`:

```
config.envoyGateway.extensionManager.backendResources = [{group: inference.networking.k8s.io, kind: InferencePool, version: v1}]
```

*Without it:* Envoy Gateway rejects the `InferencePool` backendRef of every
`HTTPRoute` KServe creates and installs a **500 direct response** on the
route. It used to be a separate `-f values-inference-pool.yaml`; it is a
default now so that an Argo CD Application with no value files is correct.
Envoy Gateway watches this kind from startup, which is why the InferencePool
CRDs ship in the same chart (§5).

**Nine are upstream AI Gateway's own published contract**, copied from
`https://raw.githubusercontent.com/envoyproxy/ai-gateway/v1.1.0/manifests/envoy-gateway-values.yaml`:

```
config.envoyGateway.extensionApis.enableBackend                                  = true
config.envoyGateway.extensionApis.enableEnvoyPatchPolicy                         = true
config.envoyGateway.extensionManager.hooks.xdsTranslator.post                     = [Translation, Cluster, Route]
config.envoyGateway.extensionManager.hooks.xdsTranslator.translation.listener.includeAll = true
config.envoyGateway.extensionManager.hooks.xdsTranslator.translation.route.includeAll    = true
config.envoyGateway.extensionManager.hooks.xdsTranslator.translation.cluster.includeAll  = true
config.envoyGateway.extensionManager.hooks.xdsTranslator.translation.secret.includeAll   = true
config.envoyGateway.extensionManager.service.fqdn.hostname = ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local
config.envoyGateway.extensionManager.service.fqdn.port      = 1063
```

Not our invention, and not optional — AI Gateway registers as an xDS
translation hook. Re-diff against upstream on every AI Gateway bump
(`UPGRADE.md` step 6); a stale `hooks.xdsTranslator.post` list silently breaks
xDS translation.

**One works around a mutable upstream default:**

```
config.envoyGateway.provider.kubernetes.shutdownManager.image = docker.io/envoyproxy/gateway:v1.9.1
```

Envoy Gateway's compiled-in default (`api/v1alpha1.DefaultShutdownManagerImage`)
is `docker.io/envoyproxy/gateway-dev:latest` — a **mutable dev tag**, in a
release artifact. Unusable disconnected, unreproducible connected. The release
image carries the same `shutdown-manager` subcommand.

**Two exist purely to preserve fidelity, not to change behaviour:**

```
nameOverride     = gateway-helm
fullnameOverride = envoy-gateway
```

A Helm dependency **alias** becomes `.Chart.Name` inside the subchart, which
drives `app.kubernetes.io/name` — and that label is part of
`Deployment.spec.selector.matchLabels`, which Kubernetes treats as
**immutable**. Without `nameOverride`, the label would be `envoy-gateway`
instead of upstream's `gateway-helm`. Holding it at upstream's value is what
makes **16 of the 17** shared objects render byte-identical, and keeps an
in-place `helm upgrade` from a plain `gateway-helm` release possible.

Changing either of these, or the alias, needs `helm uninstall` +
`helm install` — not an upgrade.

### `ai-gateway-helm` — 1

```
controller.mutatingWebhook.namespaceSelector = kubernetes.io/metadata.name in [envoy-gateway-system]
```

The `MutatingWebhookConfiguration` is cluster-scoped, matches **pod CREATE**,
and has `failurePolicy: Fail`. Upstream's `objectSelector` (left at its
default) already narrows it to envoy-gateway-managed pods, so a controller
outage blocks only Envoy data-plane pods. The namespaceSelector narrows it
further to the one namespace that has such pods — which is what keeps a
cluster-scoped `Fail`-policy webhook from being a shared-cluster risk at all.

Remove it if you enable Envoy Gateway's `gatewayNamespaceMode`, which places
Envoy pods in arbitrary application namespaces.

---

## 4. Resources added (templates this repo owns)

Five Kubernetes kinds in templates we wrote, plus upstream's presets
re-rendered. Nothing upstream is replaced.

| Resource | Chart | Why |
|---|---|---|
| `RoleBinding` → `system:openshift:scc:nonroot-v2` | envoy-gateway, envoy-ai-gateway, kserve-llmisvc | Upstream has no SCC support. Namespace-scoped, referencing the ClusterRole OpenShift auto-generates per SCC, so it grants nothing outside the release namespace. In `envoy-gateway-openshift` it **must** be a `pre-install,pre-upgrade` hook at `hook-weight: "-5"`, because upstream's certgen Job is itself a pre-install hook and Helm runs all hooks before all ordinary manifests (upstream's certgen RBAC is `-1`, the Job `0`). |
| `RoleBinding` (disabled) | lws | Present for symmetry, `enabled: false`. Upstream's `runAsNonRoot: true` with no `runAsUser` passes `restricted-v2` unaided — verified: the controller runs as UID 1000980000 under `restricted-v2`, and a test `LeaderWorkerSet` produced leader and worker pods the same way. |
| `EnvoyProxy` | envoy-ai-gateway | Pins `provider.kubernetes.envoyService.name`. Without it Envoy Gateway names the generated Service `envoy-<48-char-hash>` (from `utils.GetHashedName`), which nothing can reference from a template — so the Route would have no stable target. Also carries the service type, replicas and resources. |
| `GatewayClass`, `Gateway` | envoy-ai-gateway | Upstream ships no sample wiring. Cluster-scoped `GatewayClass` is additive; uninstalling removes only ours. |
| `Route` | envoy-ai-gateway | OpenShift-native ingress in place of a LoadBalancer. `spec.port.targetPort` must be the Service **port name** — `targetPort: 80` yields a router 503 while the Service answers 200 in-cluster. Defaults to Envoy Gateway's `irListenerPortName` convention, `lower("<PROTO>-<port>")` → `http-80`. |
| 13 × `LLMInferenceServiceConfig` | kserve-llmisvc | Upstream's presets, read from the vendored `kserve-runtime-configs` subchart's own `files/llmisvcconfigs/resources.yaml` through `.Subcharts` and rendered by `templates/llmisvcconfigs.yaml` with `argocd.argoproj.io/sync-wave: "10"`. Otherwise identical (verified by parsing both renders). Needed because the controller's `failurePolicy: Fail` webhook for this kind has no endpoints until the controller is Ready, and neither upstream template offers an annotation hook. The subchart's own copy stays off (`llmisvcConfigs.enabled: false`, guarded). |
| Sync-wave annotations | envoy-ai-gateway | `argocd.syncWave.*`: SCC binding -5, EnvoyProxy 0, GatewayClass 1, Gateway 2, Route 3. Creating the Gateway only after the AI Gateway controller is healthy replaces the plain-Helm `oc rollout restart deployment/envoy-gateway`. Helm ignores them. |
| `_validate.tpl` | envoy-gateway, envoy-ai-gateway, kserve-llmisvc | Render-time guards for mistakes that produce a healthy-looking install and fail at first use. See §7. |

---

## 5. CRDs: generated into each wrapper's `crds/`

Every CRD this stack owns is a file in a wrapper chart's `crds/`, one file per
CRD, generated by `hack/update-crds.sh` from the vendored upstream charts and
filtered by API group. The text is upstream's, spliced — not re-dumped — with
exactly two annotations added:

```yaml
argocd.argoproj.io/sync-wave: "-10"
argocd.argoproj.io/sync-options: ServerSideApply=true,Prune=false,Delete=false
```

* **wave -10** — the CRD is `Established` before any custom resource of its
  kind in the same Application is applied.
* **ServerSideApply** — `llminferenceservices` (2.7 MB), `envoyproxies`
  (1.4 MB) and others exceed the 262144-byte `last-applied-configuration`
  annotation client-side apply needs.
* **Prune=false, Delete=false** — removing a CRD garbage-collects every custom
  resource of that kind, cluster-wide. Neither a CRD dropped upstream nor a
  deleted Application may do that; `inferencepools` in particular may be shared.

One file per CRD because Helm refuses to load a chart file over 5 MiB
(`MaxDecompressedFileSize`), and the `serving.kserve.io` CRDs are 5.4 MB
together. `hack/update-crds.sh --check` fails if the committed files drift from
the vendored charts; the script also fails if any `gateway.networking.k8s.io`
CRD would be written.

| CRD group | Chart | Generated from | Why there |
|---|---|---|---|
| `gateway.envoyproxy.io` (8) | envoy-gateway | `gateway-crds-helm` with `crds.gatewayAPI.enabled=false` | `gateway-helm`'s own `crds` subchart cannot separate these from the Gateway API CRDs (Helm does not template `crds/`); upstream's separate CRD chart can |
| `inference.networking.k8s.io`, `inference.networking.x-k8s.io` (2) | envoy-gateway | `kserve-llmisvc-resources` with `createGIECRDs=true` | Envoy Gateway watches `InferencePool` (`backendResources`) from startup, so it ships with Envoy Gateway. Rendered from KServe's chart so the schema matches the controller |
| `aigateway.envoyproxy.io` (6) | envoy-ai-gateway | `ai-gateway-crds-helm` (separate upstream chart) | The AI Gateway chart itself ships none |
| `serving.kserve.io` (3) | kserve-llmisvc | `kserve-llmisvc-crd` (separate upstream chart) | The controller chart itself ships none |
| `llm-d.ai` (2) | kserve-llmisvc | `kserve-llmisvc-resources` with `createGIECRDs=true` | `createGIECRDs=false` keeps them out of `templates/` |
| `leaderworkerset.x-k8s.io`, `disaggregatedset.x-k8s.io` (3) | lws | *not generated* | Upstream already ships them in the subchart's `crds/`; Argo CD renders them by default. They carry no wave or `Delete=false` — see README, Uninstall |

**This is also KServe's own method.** `llmisvc-dependency-install.sh` installs
Envoy Gateway by group-filtering the CRDs and then passing `--skip-crds`. The
one thing it does not do is disable the safe-upgrade admission policy, which
lives in `templates/` and is therefore unaffected by `--skip-crds`.

Plain Helm only — Helm 4.3.0 behaviour, measured with a throwaway CRD, because
Helm's own `--skip-crds` help text ("installed if not already present")
describes Helm 3. This is why `hack/install-crds.sh` still exists for the
plain-Helm path; Argo CD applies `crds/` on every sync like any manifest:

| Operation | Effect on an existing CRD in `crds/` |
|---|---|
| `helm install` | **Overwrites it** via server-side apply (manager becomes `helm/Apply`) |
| `helm install --skip-crds` | Skips entirely |
| `helm upgrade` | Does nothing — never touches `crds/` |
| `helm uninstall` | Never deletes `crds/` content |

---

## 6. Deployment constraints

Not chart changes, but part of the delta. Nothing *required* is an overlay or
a flag any more — every required setting is a default — so these are the
whole list.

| Constraint | Chart | Consequence if ignored |
|---|---|---|
| Destination namespace `kserve` | kserve-llmisvc | The `llminferenceservices` CRD hardcodes `namespace: kserve` in its conversion-webhook `clientConfig` and its `cert-manager.io/inject-ca-from`; neither is templated upstream. Anywhere else, every *read* of an `LLMInferenceService` fails. The chart refuses to render |
| Destination namespace `lws-system` | lws | The `leaderworkersets` CRD hardcodes its conversion webhook to `lws-webhook-service.lws-system` |
| `ServerSideApply=true` on the Application | all | The LWS CRDs (upstream, unannotated) exceed the client-side-apply annotation limit. The generated CRDs carry it per resource |
| No `skipCrds` on the Application | all | The CRDs are in the charts now; skipping them leaves the Applications' custom resources with no kind |
| Application sync order: envoy-gateway → envoy-ai-gateway, lws → kserve-llmisvc | all | Cross-chart dependencies (`EnvoyProxy`, `InferencePool`, `LeaderWorkerSet` CRDs). A sync `retry` converges without it, after a few failed attempts |
| Plain Helm only: two passes for kserve-llmisvc (`runtimeConfigs.enabled=false`, then `true`) | kserve-llmisvc | Helm applies all manifests in one pass, so the presets hit the controller's webhook before it has endpoints. Argo CD's wave 10 replaces this. Formerly two separate charts/releases |
| Plain Helm only: `oc rollout restart deployment/envoy-gateway` after the AI Gateway chart | envoy-gateway | Gateways stay `PROGRAMMED=False`. Argo CD's Gateway wave replaces this |

---

## 7. Render-time guards

Three of the bugs found while building this passed `helm lint`, and one also
passed a 404 smoke test. These guards turn the remaining silent failures into
render errors.

| Guard | Chart | Blocks |
|---|---|---|
| `crds.enabled` must be false | envoy-gateway | Overwriting the cluster's Gateway API CRDs |
| `crds.gatewayAPI.safeUpgradePolicy.enabled` must be false | envoy-gateway | Installing the cluster-wide `Fail`-policy admission policy (which `--skip-crds` does *not* stop) |
| `extensionManager` set ⇒ `service.fqdn.hostname` non-empty | envoy-gateway | Gateways stuck `PROGRAMMED=False`, looking like a data-plane fault |
| namespace must be `kserve` | kserve-llmisvc | An install that looks healthy until the first read of an `LLMInferenceService` |
| `kserveGateway` must be `<namespace>/<name>` | kserve-llmisvc | A bare name silently resolving to the release namespace |
| `createGIECRDs` must be false | kserve-llmisvc | `helm uninstall` deleting cluster-scoped CRDs; duplicate, unguarded copies of the `crds/` files |
| subchart presets off while `runtimeConfigs.enabled` | kserve-llmisvc | Every preset rendered twice, once without its sync wave |
| `gateway.envoyGatewayNamespace` == `ai-gateway.envoyGateway.namespace` | envoy-ai-gateway | A Route pointing at an endpoint-less Service |
| SCC enabled ⇒ a subject is set | all with SCC | A binding that grants nothing, so pods fail admission |

All nine were tested by deliberately tripping them.

---

## 8. Version deviations from KServe's pins

**KServe leads the versions.** Every component comes from KServe v0.21.0's
`llmisvc-dependency-install.sh`, not from each project's newest release — that
is why LeaderWorkerSet is v0.10.0 and not the available v0.11.0.

Two deviations, both forced:

| KServe pins | Ours | Why |
|---|---|---|
| `GATEWAY_API_VERSION=v1.5.1` | v1.4.1 standard | Owned by `cluster-ingress-operator`. Never ours to change |
| `ENVOY_GATEWAY_VERSION=v1.8.1` | **v1.9.1** | v1.8.1 **cannot start** on a cluster with standard-channel Gateway API. See below |

### Why v1.8.1 cannot be used, even from a clean install

Tested rather than assumed. A clean-room `helm install` of **upstream**
`gateway-helm` v1.8.1 — brand-new namespace, brand-new release, no wrapper
chart, no leftover config — crash-loops with `exitCode=1`:

```
error  config-loader  hook error  {"error": "failed to create kubernetes provider:
  failed to create provider Kubernetes: failed to create gatewayapi controller:
  error watching resources: no matches for kind \"ListenerSet\" in version
  \"gateway.networking.k8s.io/v1\""}
```

`ListenerSet` is an **experimental-channel** Gateway API kind; this cluster
serves **standard**, so the CRD does not exist. v1.8.1 registers the watch
unconditionally in `watchResources()`:

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

So this is a **startup-time API discovery failure in the controller binary**,
not a Helm release-state problem. Uninstalling and reinstalling cannot change
it: there is no config knob, and the watch is registered before any reconcile.
The probe fields each version has:

| | CRD-existence probes |
|---|---|
| v1.8.1 | backend, btp, ctp, eep, ep, epp, hrf, serviceImport, sp, tcpRoute, udpRoute |
| v1.9.1 | all of those **+ listenerSet**, btls, grpcRoute, tlsRoute, extBackend |

Options, and why v1.9.1 was chosen:

| Option | Verdict |
|---|---|
| Install experimental-channel Gateway API cluster-wide | **No.** Overwrites the ingress-operator's standard-channel CRDs for every tenant |
| Install only `listenersets.gateway.networking.k8s.io` from the experimental channel | Additive rather than destructive, so *possible*. Not taken: it adds an experimental kind to an API group the ingress-operator owns and continuously reconciles. Untested here by choice — ask if you want it evaluated |
| Envoy Gateway v1.9.1 | **Taken.** Needs no cluster-scoped change at all |

Compatibility was checked, not assumed: `ExtensionManager.BackendResources`
(the `backendResources` field in `values.yaml`) exists in **both** versions; AI
Gateway v1.1.0 runs against v1.9.1 with the Gateway reaching
`PROGRAMMED=True` and the `InferencePool` ext_proc cluster present in the Envoy
config dump; and the measured Gateway API field gap to v1.4.1 is **identical**
for v1.5.1 and v1.6.1.

**Re-check on every KServe bump** — the moment KServe pins v1.9.x or later,
drop the exception:

```bash
curl -fsSL "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_NEW/internal/provider/kubernetes/controller.go" \
  | sed -n '/^type gatewayAPIReconciler struct/,/^}/p' \
  | grep -c listenerSetCRDExists        # 1 = safe on standard channel, 0 = will crash-loop
```

---

## 9. Considered and rejected

Each was attempted and measured, not reasoned about.

| Idea | Result |
|---|---|
| Drop the KServe controller's `runAsUser: 1000` so `restricted-v2` assigns a UID, needing no SCC grant | **Impossible through Helm.** Parent values merge *into* subchart defaults, so a key cannot be removed from a subchart map. `runAsUser: null` leaves `1000`; restating all 7 keys of `containerSecurityContext` without it also leaves `1000`. Verified both ways. The only alternative is forking the template — a bigger delta than one RoleBinding |
| Pin the AI Gateway image tags for mirroring | **Removed as redundant.** Upstream's `repository` already defaults to the same value and `tag: ""` resolves to the chart `appVersion`; the render is identical. Its only override now is the cert-manager one Argo CD forces |
| Pin the Envoy Gateway control-plane image | **Removed as redundant.** Upstream's `eg.image` helper already defaults to `gateway:{{ .Chart.Version }}` |
| Use `--skip-crds` / Argo CD `skipCrds` *instead of* `crds.enabled=false` | **Insufficient.** It does not stop the admission policy in `templates/`, it is not a value, and it would also skip this repo's own `crds/` |
| Let the KServe presets stay in the subchart and rely on sync `retry` | **Rejected.** Converges eventually, but every first sync fails on the webhook; a sync wave makes it correct on the first attempt |
| Put the InferencePool CRDs in the kserve chart with the other KServe-derived CRDs | **Rejected.** Envoy Gateway watches that kind from startup and syncs first; the CRD must already exist |
| Fold LWS into the kserve chart | **Impossible.** The LWS CRD hardcodes `lws-system`, the KServe CRD hardcodes `kserve`, and an Application has one destination namespace |
| Follow KServe's Envoy Gateway v1.8.1 pin | **Blocked** — see §8 |
| Let KServe create its own `kserve-ingress-gateway` and override nothing | **Possible, not chosen.** Costs a second Envoy data plane, Service and Route. One override reuses the Gateway that already exists |
| Adopt KServe's `docs/OPENSHIFT_GUIDE.md` approach | **Not applicable, and worse where it overlaps.** It targets KServe 0.14 / OpenShift 4.17 / classic `InferenceService` on Knative + Istio or Kourier, installed from raw manifests — no Helm, no `LLMInferenceService`. Its SCC advice is `oc adm policy add-scc-to-user anyuid` (the most permissive SCC short of `privileged`) plus `oc patch` to strip `runAsUser` from a Deployment — which makes `kubectl-patch` the field manager and breaks the next `helm upgrade` with a server-side-apply conflict |

---

## 10. What a pure-upstream install would cost

If you removed every change in this report and installed the upstream
charts as-is on this cluster:

1. Gateway API v1.6.1 experimental CRDs would overwrite the ingress-operator's
   v1.4.1 standard ones, cluster-wide.
2. A `failurePolicy: Fail` admission policy would start rejecting the ingress
   operator's own CRD writes.
3. Every Envoy Gateway pod would fail SCC admission (`runAsUser: 65532` vs the
   namespace range), starting with the certgen pre-install hook.
4. The KServe controller pod would fail SCC admission (`runAsUser: 1000`).
5. Envoy data-plane pods would try to pull `gateway-dev:latest`.
6. Nothing would expose the gateway — no Service name to reference, no Route.
7. `helm uninstall` of the KServe chart would delete every `InferencePool` on
   the cluster.
8. On a disconnected cluster, the Envoy data plane and both KServe images would
   not resolve.

Items 3–6 are ordinary OpenShift packaging. Items 1, 2 and 7 are the ones that
affect other tenants, and they are the reason this wrapper exists.

---

## 11. Verifying this report

```bash
./hack/list-patches.sh            # re-derive §1-§3 from the charts
./hack/list-images.sh --check     # mirror list still matches the charts
./hack/update-crds.sh --check     # §5: committed crds/ match the vendored charts

# the vendored subcharts are unmodified upstream artifacts
TMP=$(mktemp -d)
helm pull oci://docker.io/envoyproxy/gateway-helm              --version v1.9.1       -d "$TMP"
helm pull oci://docker.io/envoyproxy/ai-gateway-helm           --version v1.1.0       -d "$TMP"
helm pull oci://registry.k8s.io/lws/charts/lws                 --version v0.10.0      -d "$TMP"
helm pull oci://ghcr.io/kserve/charts/kserve-llmisvc-resources  --version v0.21.0-rc1 -d "$TMP"
helm pull oci://ghcr.io/kserve/charts/kserve-runtime-configs    --version v0.21.0-rc1 -d "$TMP"
shasum -a 256 "$TMP"/*.tgz charts/*/charts/*.tgz | sort -k1,1   # each digest twice
rm -rf "$TMP"
```

Keep this file in step with [`UPGRADE.md`](UPGRADE.md): step 3 diffs upstream's
values per chart, which is where a renamed or removed key shows up.
