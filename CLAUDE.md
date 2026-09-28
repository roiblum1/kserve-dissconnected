# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Five Helm wrapper charts installing Envoy Gateway v1.9.1, Envoy AI Gateway
v1.1.0, LeaderWorkerSet v0.10.0 and KServe LLMInferenceService v0.21.0 on
OpenShift, plus a CRD installer and an `oc mirror` config for disconnected
installs. `README.md` is the user-facing doc. [`PATCHES.md`](PATCHES.md) is the
authoritative audit of every deviation from upstream and must be updated
whenever a chart value or added resource changes — run `hack/list-patches.sh`
and reconcile it. README's "Delta from the upstream charts" section is the
narrative version of the same thing; keep the two consistent.
[`UPGRADE.md`](UPGRADE.md) is the authoritative version-bump runbook.

```
charts/envoy-gateway-openshift/          wraps oci://docker.io/envoyproxy/gateway-helm v1.9.1
  values-inference-pool.yaml             REQUIRED with KServe: extensionManager.backendResources
charts/envoy-ai-gateway-openshift/       wraps oci://docker.io/envoyproxy/ai-gateway-helm v1.1.0
  values-kserve.yaml                     REQUIRED with KServe: allowedRoutes.namespaces.from: All
charts/lws-openshift/                    wraps oci://registry.k8s.io/lws/charts/lws v0.10.0
charts/kserve-llmisvc-openshift/         wraps oci://ghcr.io/kserve/charts/kserve-llmisvc-resources v0.21.0-rc1
charts/kserve-runtime-configs-openshift/ wraps oci://ghcr.io/kserve/charts/kserve-runtime-configs v0.21.0-rc1
hack/install-crds.sh                     every CRD this stack owns; never Gateway API
hack/charts/                              vendored CRD-source charts, so the above runs offline
hack/list-images.sh                       derives the mirror list from the charts; --check
hack/list-patches.sh                      derives every value change from the vendored subcharts
hack/resolve-digest.sh                    image digest without pulling
mirror-config.yaml                        oc mirror v2 ImageSetConfiguration
PATCHES.md                                audit report: every change from upstream
UPGRADE.md                                version-bump runbook + checklist
```

Disconnected is the target. Every upstream subchart and CRD chart is vendored in
the repo, so no step of the install path needs a chart registry.

**KServe leads the versions.** Component versions come from KServe v0.21.0's
`llmisvc-dependency-install.sh`, not from each project's newest release. Two
forced exceptions: Gateway API (cluster-owned) and Envoy Gateway — see
invariant 14. Re-derive the matrix on every bump:

```bash
curl -sfL "https://github.com/kserve/kserve/releases/download/v0.21.0/llmisvc-dependency-install.sh" \
  | grep -E '^(CERT_MANAGER|ENVOY_GATEWAY|ENVOY_AI_GATEWAY|LWS|GATEWAY_API|GIE|LLMD_ROUTER|KSERVE)_VERSION='
```

## The cluster is shared

Assume other people are using the target cluster. Before creating anything
cluster-scoped, check whether it already exists and who manages it:

```bash
oc get crd <name> --show-managed-fields -o jsonpath='{.metadata.managedFields[*].manager}'
```

Namespaced resources in `envoy-gateway-system`, `envoy-ai-gateway-system`,
`kserve` and `lws-system` are fair game. Cluster-scoped resources are not, with
four exceptions this stack already owns: its own CRD groups, the
`envoy-ai-gateway` GatewayClass, the `default` ClusterStorageContainer, and its
own RBAC/webhook configs.

`inferencepools.inference.networking.k8s.io` deserves particular care: it is a
Gateway API Inference Extension CRD that another product on the cluster may also
use. Check `oc get inferencepool -A` before touching it.

**Never** run anything destructive: no `oc delete crd` on shared groups, no
`oc delete ns` on namespaces you did not create, no edits to `ingresses.config/cluster`,
`featuregate/cluster`, or anything in `openshift-*`.

## Hard invariants — do not regress these

1. **`envoy-gateway.crds.enabled` stays `false`.** Setting it `true` installs
   Gateway API v1.6.1 *experimental* CRDs over the ingress-operator's v1.4.1
   standard ones, and creates a `safe-upgrades.gateway.networking.k8s.io`
   ValidatingAdmissionPolicy (`failurePolicy: Fail`, matches all CRD writes)
   that denies `bundle-version ^v1\.[0-4]` — i.e. it starts rejecting the
   OpenShift ingress-operator's own reconcile writes, cluster-wide.

   Do not "improve" this with `--skip-crds` or by trusting Helm to skip
   existing CRDs. Measured on Helm 4.3.0 with a throwaway CRD:
   `helm install` **overwrites** existing `crds/` content via server-side apply
   (manager `helm/Apply`) — despite the `--skip-crds` help text claiming CRDs
   are "installed if not already present", which was Helm 3 behaviour.
   `helm upgrade` never touches `crds/`; `helm uninstall` never deletes it;
   `--skip-crds` does protect but is a CLI flag, not a value, and is
   all-or-nothing so it would also skip Envoy Gateway's own 8 CRDs. Helm does
   not template `crds/`, so no value can gate the Gateway API files
   selectively — that is why upstream's separate `gateway-crds-helm` chart
   (CRDs in `templates/`, hence gateable) is the sanctioned path.

2. **Gateway API CRDs are never created, patched or deleted here.** They belong
   to `cluster-ingress-operator`. `hack/install-crds.sh` asserts this after
   every run.

3. **SCC is `nonroot-v2`, never `anyuid` or `privileged`.** All four images
   declare a non-root `USER`, so `MustRunAsNonRoot` is sufficient. Verify with
   the registry rather than assuming.

4. **The SCC RoleBinding in `envoy-gateway-openshift` must stay a
   `pre-install,pre-upgrade` hook with `hook-weight: "-5"`.** Upstream's certgen
   Job is a pre-install hook, and Helm runs all hooks before all ordinary
   manifests; as a plain resource the binding arrives too late and certgen fails
   SCC admission. Upstream's certgen RBAC is at `-1`, the Job at `0`.

5. **Dependency aliases must be lowercase and DNS-safe.** A Helm alias becomes
   `.Chart.Name` inside the subchart, so `alias: envoyGateway` yields
   `envoy-gateway-envoyGateway-certgen`, which the API server rejects. Current
   aliases: `envoy-gateway`, `ai-gateway`, both with `fullnameOverride`.

6. **CRDs stay out of every chart**, installed by `hack/install-crds.sh`. Note
   `crds/` content is *not* stored in the release Secret (the current release
   manifest is ~13 KB with 0 CRDs), so chart size is not the reason — see
   invariant 1 for the real one. Re-run the script on every version bump,
   because `helm upgrade` never updates CRDs.

   Three mechanisms, all handled by the script:
   * `gateway-helm` gates its Gateway API + EG CRDs behind the `crds` **subchart
     condition** (`crds.enabled`); a disabled subchart's `crds/` is skipped
     entirely, which is why `crds.enabled: false` actually works.
   * `lws` ships CRDs in `crds/` with no gate — install it with `--skip-crds`.
     Forgetting that at the *same* version is harmless (verified: server-side
     apply only conflicts when content differs, so Helm merely co-owns the
     identical object). At a *different* version it does conflict.
   * `kserve-llmisvc-resources` renders the Inference Extension and llm-d CRDs
     into `templates/` behind `createGIECRDs`, so Helm would **delete** them on
     uninstall. Keep it `false`; `templates/_validate.tpl` enforces it.

7. **Three image references are not covered by `global.imageRegistry`** and must
   be set explicitly in the mirror overlays: the Envoy data plane, the
   shutdown-manager, and AI Gateway's `extProc`.

8. **Keep `envoyService.name` pinned** in the EnvoyProxy. Without it Envoy
   Gateway names the Service `envoy-<48-char-hash>` and nothing can reference
   it. Only the Service name is pinnable — the Deployment, ReplicaSet and
   ServiceAccount stay hashed, so select those by label
   (`gateway.envoyproxy.io/owning-gateway-name`).

9. **A Route's `targetPort` names the Service port, never the port number.**
   `targetPort: 80` yields a router 503 while the Service answers 200
   in-cluster. The correct value is Envoy Gateway's `irListenerPortName`
   convention, `lower("<PROTOCOL>-<port>")` → `http-80`.

10. **`charts/kserve-llmisvc-openshift` installs only in namespace `kserve`.**
    The upstream `llminferenceservices` CRD hardcodes
    `conversion.webhook.clientConfig.service.namespace: kserve` and
    `cert-manager.io/inject-ca-from: kserve/llmisvc-serving-cert`; neither is
    templated. Anywhere else, the CRD's conversion webhook points at a
    nonexistent Service and every read of an LLMInferenceService fails. The
    chart fails the render (`openshift.enforceNamespace`). Consequence:
    `helm lint` must be run with `-n kserve` for that chart and for
    `kserve-runtime-configs-openshift`.

11. **`kserve-llmisvc` and `kserve-runtime-configs` must be two releases, in
    that order.** The runtime-configs chart creates `LLMInferenceServiceConfig`
    CRs; the llmisvc chart installs a `ValidatingWebhookConfiguration` for that
    kind with `failurePolicy: Fail`. Helm applies all manifests of a release in
    one pass before waiting, so combined they would be rejected by a webhook
    with no endpoints. Their `Chart.yaml` versions must stay equal.

12. **The two KServe overlays are not optional.** With KServe installed,
    `charts/envoy-gateway-openshift` needs
    `-f values-inference-pool.yaml` (else Envoy Gateway rejects the
    `InferencePool` backendRef and serves a **500 direct response** on every
    model route) and `charts/envoy-ai-gateway-openshift` needs
    `-f values-kserve.yaml` (else `HTTPRoute`s created in model namespaces are
    rejected as `NotAllowedByListeners`). `helm upgrade` does not remember `-f`
    flags, so both must be repeated on every upgrade.

13. **LWS needs no SCC binding.** Upstream sets `runAsNonRoot: true` with no
    `runAsUser`, so `restricted-v2` assigns a UID from the namespace range.
    Verified: the controller runs as 1000980000 under `restricted-v2`, and a
    test `LeaderWorkerSet` produced leader and worker pods under `restricted-v2`
    too. `openshift.securityContextConstraints.enabled` is `false` there — do
    not "fix" it. The llmisvc controller is the opposite: it asks for UID 1000,
    so it does need `nonroot-v2`.

14. **Envoy Gateway stays at v1.9.1, not KServe's pinned v1.8.1.** v1.8.1
    registers the `ListenerSet` watch unconditionally in `watchResources()`
    and refuses to start when the CRD is absent. Proven with a clean-room
    install of the upstream chart in a fresh namespace — it is a startup-time
    API discovery failure in the binary, so uninstall/reinstall cannot help:

    ```
    error watching resources: no matches for kind "ListenerSet" in version
    "gateway.networking.k8s.io/v1"
    ```

    `ListenerSet` is experimental-channel Gateway API; this cluster serves
    standard. v1.9.1 added `listenerSetCRDExists` (with `btlsCRDExists` and
    `grpcRouteCRDExists`) and probes first. There is no config knob in v1.8.1.
    Do not "fix" this by installing experimental Gateway API CRDs — that is
    invariant 2. `ExtensionManager.BackendResources` exists in both versions,
    so the KServe integration is unaffected. Drop the exception if KServe ever
    pins v1.9.x or later.

15. **`templates/_validate.tpl` in `envoy-gateway-openshift` must keep
    guarding both CRD knobs.** It fails the render on
    `crds.enabled=true` and on `crds.gatewayAPI.safeUpgradePolicy.enabled=true`.
    The second matters because `--skip-crds` does not stop `templates/`, so the
    admission policy would install even on a "safe" command line.

## Version-bump procedure

**Follow [`UPGRADE.md`](UPGRADE.md).** It is the authoritative runbook: every
command, the order, the rollback path, and a checklist. Do not improvise a
version bump from memory, and keep `UPGRADE.md` updated when the procedure
changes.

Why bumping `Chart.yaml` is not enough — the four things that live outside the
charts, each a silent failure if skipped:

1. **Two image defaults are compiled into the Envoy Gateway Go binary** (the
   data plane and the shutdown-manager). They never appear in `helm template`,
   so nothing warns you when they change. The shutdown-manager default has
   historically been a mutable `gateway-dev:latest`.
2. **`helm upgrade` never touches `crds/`** — CRDs need an explicit
   `hack/install-crds.sh` run on every bump, whatever installed them.
3. **The AI Gateway ↔ Envoy Gateway extension-hook contract** ships as a values
   file in the ai-gateway repo, not in the chart. A stale
   `hooks.xdsTranslator.post` list silently breaks xDS translation.
4. **The CRD hazard must be re-confirmed**, not assumed unchanged — including
   whether upstream has finally added a knob to gate the Gateway API CRDs
   selectively, which is the one upstream change that would shrink this chart's
   delta.

Two operational traps when upgrading:

* **Helm does not remember `-f` flags.** An upgrade without the same
  `values-mirror.yaml` / `values-loadbalancer.yaml` overlays silently reverts to
  the committed defaults.
* **`helm rollback` does not roll back CRDs** — they are not part of the
  release. After a rollback you are running old controllers against new CRD
  schemas.

## Verification sequence

Run all of it after any chart change. `helm lint` passing is not sufficient —
all three bugs found while building this (invalid uppercase resource names,
hook-ordering SCC failure, and the Route `targetPort` 503) passed lint. The
last one also passed a 404 smoke test, so **prove the data path forwards real
traffic**, not just that Envoy answers: apply a throwaway `HTTPRoute` with a
`RequestRedirect` filter and assert the 302 and its `Location` header. The
README's "Proving the data path forwards traffic" section has the manifest.

```bash
# Note -n kserve: the llmisvc chart refuses to render elsewhere (invariant 10).
helm lint charts/envoy-gateway-openshift charts/envoy-ai-gateway-openshift charts/lws-openshift
helm lint charts/kserve-llmisvc-openshift charts/kserve-runtime-configs-openshift -n kserve

# no CRDs or admission policies may be rendered by ANY chart
for c in envoy-gateway-openshift:envoy-gateway-system \
         envoy-ai-gateway-openshift:envoy-ai-gateway-system \
         lws-openshift:lws-system \
         kserve-llmisvc-openshift:kserve \
         kserve-runtime-configs-openshift:kserve; do
  printf '%-34s CRD/VAP=%s uppercase=%s gateway-dev=%s\n' "${c%%:*}" \
    "$(helm template x "charts/${c%%:*}" -n "${c##*:}" | grep -cE 'kind: CustomResourceDefinition|kind: ValidatingAdmissionPolicy')" \
    "$(helm template x "charts/${c%%:*}" -n "${c##*:}" | grep -E '^  name:' | grep -c '[A-Z]')" \
    "$(helm template x "charts/${c%%:*}" -n "${c##*:}" | grep -c 'gateway-dev')"
done   # every column must be 0

# the mirror list must still match what the charts reference
./hack/list-images.sh --check

./hack/install-crds.sh --dry-run
```

Live checks after install:

```bash
# SCC per namespace: nonroot-v2 in the three gateway/kserve namespaces,
# restricted-v2 in lws-system (invariant 13)
for ns in envoy-gateway-system envoy-ai-gateway-system kserve lws-system; do
  echo "== $ns"
  oc get pods -n $ns -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,SCC:.metadata.annotations.openshift\.io/scc'
done

# shutdown-manager must NOT be gateway-dev:latest
oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'

oc get gateway -n envoy-ai-gateway-system    # PROGRAMMED=True
curl -skI "https://$(oc get route envoy-ai-gateway -n envoy-gateway-system -o jsonpath='{.spec.host}')/"
# 404 = success before any route exists
# 503 = either the Route targetPort is wrong (invariant 9) or no endpoints

# the two KServe overlays must be in effect (invariant 12)
oc get cm envoy-gateway-config -n envoy-gateway-system \
  -o jsonpath='{.data.envoy-gateway\.yaml}' | grep -A3 backendResources
oc get gateway envoy-ai-gateway -n envoy-ai-gateway-system \
  -o jsonpath='{.spec.listeners[*].allowedRoutes.namespaces.from}{"\n"}'   # All

oc get llminferenceserviceconfig -n kserve --no-headers | wc -l   # 13
oc get certificate llmisvc-serving-cert -n kserve                 # READY=True

# safety re-check
oc get crd gateways.gateway.networking.k8s.io --show-managed-fields \
  -o jsonpath='{.metadata.managedFields[*].manager}'   # ingress-operator, kube-apiserver only
oc get co ingress -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
```

For KServe, `helm install` succeeding proves nothing about routing. Apply a
throwaway `LLMInferenceService` and assert three things — the README's
"Proving the KServe data path" section has the manifest and the commands:

1. the generated `HTTPRoute` is `Accepted=True` **and** `ResolvedRefs=True`
   (ResolvedRefs is the `InferencePool` backendRef resolving, i.e. proof that
   `values-inference-pool.yaml` is in effect);
2. the Envoy config dump contains an `endpointpicker_*_ext_proc` cluster and
   **zero** routes with a 500 direct response;
3. the endpoint-picker pod logs show it processed the request.

On a GPU-less cluster the model pod stays in its `storage-initializer` init
container and the endpoint picker answers 400 — expected, not a wiring failure.

## Install order matters

```
CRDs
  -> envoy-gateway-openshift        -f values-inference-pool.yaml
  -> envoy-ai-gateway-openshift     -f values-kserve.yaml
  -> oc rollout restart deploy/envoy-gateway
  -> lws-openshift                  --skip-crds
  -> kserve-llmisvc-openshift       -n kserve
  -> kserve-runtime-configs-openshift -n kserve
```

The restart is not optional: Envoy Gateway is configured with an
`extensionManager` pointing at the AI Gateway controller, which does not exist
when chart 1 is installed. Gateways stay `PROGRAMMED=False` until it reconnects.

The last two are separate releases in that order — see invariant 11.
`cert-manager` must already exist before the llmisvc chart;
`hack/install-crds.sh` checks for it when its `kserve` component runs.

## Facts that are easy to get wrong

* The Envoy **data plane** runs in `envoy-gateway-system`, not next to the
  Gateway. The stable Service and Route therefore live there too.
* Envoy Gateway shifts listener ports below 1024 by **+10000**, so a listener on
  80 is served on container port 10080. `gateway.listener.port` and
  `gateway.listener.containerPort` must stay consistent.
* The generated Envoy Service name is pinned via
  `EnvoyProxy.spec.provider.kubernetes.envoyService.name`. Everything else
  Envoy Gateway generates keeps a hashed name.
* Gateway API on the verified cluster is **v1.4.1 standard**, while Envoy
  Gateway v1.9.1 builds against v1.6.1. Measured gap: `GatewayClass`,
  `GRPCRoute` and `BackendTLSPolicy` are field-identical; `Gateway` is missing
  only ListenerSet and v1.6 `spec.tls` fields; `HTTPRoute` is missing only the
  native `cors` filter, which the v1.4.1 `type` enum **rejects at admission**
  rather than pruning silently. Use Envoy Gateway's `SecurityPolicy` for CORS.
  Do not "fix" this by installing Gateway API CRDs — see invariant 2.
* The `ai-gateway-extproc` sidecar is **absent** until an `AIGatewayRoute`
  attaches to the Gateway. That is not a failure.
* `oc get infrastructure cluster -o jsonpath='{.status.platform}'` is `None` on
  the test cluster: `LoadBalancer` Services never get an address, so the
  default is `ClusterIP` + Route. **The intended production cluster does have a
  load balancer** — switch with
  `-f charts/envoy-ai-gateway-openshift/values-loadbalancer.yaml`, which sets
  `service.type: LoadBalancer`, `externalTrafficPolicy: Local` and
  `route.create: false`. Always re-check `status.platform` before assuming.
* A dependency alias becomes `.Chart.Name` inside the subchart, which drives
  `app.kubernetes.io/name` — and that label is part of
  `Deployment.spec.selector.matchLabels`, which is **immutable**.
  `envoy-gateway.nameOverride: gateway-helm` exists to hold that label at
  upstream's value; do not remove it, and never change `nameOverride`,
  `fullnameOverride` or the alias on a live release (it needs an
  uninstall/reinstall, not an upgrade).
* In a values overlay, a key with **only comments** under it parses as `null`
  and overrides the subchart's default with nil — e.g. a bare `global:` breaks
  `ai-gateway-helm` with `nil pointer evaluating interface {}.imagePullSecrets`.
  Comment out the parent key too, or give it a real value.
* Hand-patching a Helm-managed object with `oc patch` makes `kubectl-patch` the
  field manager and the next `helm upgrade` fails with a server-side-apply
  conflict. Change values and upgrade instead; if it already happened, delete
  the object and let Helm recreate it.
* `helm list -n <ns> -a` / `--all` is not valid in the installed Helm 4.x; use
  `helm list -n <ns>`.
* **Six images cannot be redirected by any Helm value.** The vLLM and llm-d
  references inside the `LLMInferenceServiceConfig` presets are literals in
  upstream's `files/llmisvcconfigs/resources.yaml`. `global.imageRegistry` does
  not reach them. In a disconnected cluster only an `ImageDigestMirrorSet` can,
  which is why `mirror-config.yaml` (an `oc mirror` `ImageSetConfiguration`)
  replaced the old flat image list. `values-mirror.yaml` overlays still exist
  for mirrors without a cluster-wide mirror map, but they cannot cover these
  six.
* **KServe v0.21.0's charts are labelled `v0.21.0-rc1`.** The v0.21.0 GitHub
  release ships tarballs with that name and ghcr.io has no `v0.21.0` tag; the
  `-rc1` OCI artifacts are byte-identical to the release's (verified by
  diffing both extracted trees). `v0.21.0-rc1` is the correct pin. Re-check on
  the next bump in case upstream starts publishing a final tag.
* **KServe pins Envoy Gateway v1.8.1**, this repo runs v1.9.1 — forced, not
  preference. See invariant 14 for the crash log and the source diff.
  `llmisvc-dependency-install.sh` in the KServe release is the authoritative
  list of what KServe expects; re-derive it on every bump.
* **A key cannot be removed from a subchart's map via parent values.** Helm
  merges the parent *into* the subchart default, so setting a key to `null`
  leaves the default in place, and even restating the whole map without the key
  leaves it in place. Verified on
  `kserve.llmisvc.controller.containerSecurityContext.runAsUser`. This is why
  the SCC RoleBinding exists instead of "just dropping runAsUser" — the only
  alternative is forking the upstream template.
* **KServe's `docs/OPENSHIFT_GUIDE.md` does not apply here.** It targets KServe
  0.14 / OpenShift 4.17 / classic `InferenceService` on Knative + Istio or
  Kourier, installed from raw manifests — no Helm, no `LLMInferenceService`. Its
  SCC advice is `oc adm policy add-scc-to-user anyuid` plus `oc patch` to strip
  `runAsUser` from a Deployment, both of which this repo deliberately avoids
  (invariant 3, and the `oc patch` field-manager gotcha below). Do not cite it
  as a reason to change these charts.
* **Mirroring images does not make a model available.** `spec.model.uri: hf://…`
  needs egress to Hugging Face. Disconnected clusters need S3/PVC or a
  pre-seeded `ClusterStorageContainer`.
* The llmisvc controller reconciles into the **model's** namespace, not
  `kserve`: `HTTPRoute`, `InferencePool`, the vLLM Deployment and the endpoint
  picker all land next to the `LLMInferenceService`.
* `LLMInferenceService` can report `InferencePoolReady=False / WaitingForGateway`
  while routing works perfectly. Envoy Gateway v1.9.1 accepts the
  `InferencePool` into its resource tree but does not write `status.parents`
  back, which is what KServe waits on. Verify the data path instead of the
  condition.

## Conventions

* Prefer overriding upstream values over forking upstream templates. If a fork
  becomes unavoidable, record it in the README delta section with the reason.
* Any new override gets a comment in `values.yaml` saying *why*, not *what* —
  the what is already visible.
* The mirror list is **derived, not maintained**: `hack/list-images.sh` renders
  every chart and extracts the image references, and `--check` fails if
  `mirror-config.yaml` has drifted. Run `--check` after any value change that
  could touch an image. Two extraction quirks it exists to handle: the ext_proc
  sidecar appears only as `--extProcImage=` on the AI Gateway controller (the
  webhook injects it at pod-creation time), and some refs are unqualified
  (`kserve/...`) upstream.
* `mirror-config.yaml` entries use **tags**, with digests in trailing comments
  for verification. Mirroring a tag copies the manifest it points at, so a
  chart that pins `...@sha256:...` still resolves against the mirror, and
  `--check` therefore compares on `repo:tag` only.
