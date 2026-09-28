# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Four Helm wrapper charts installing Envoy Gateway v1.9.1, Envoy AI Gateway
v1.1.0, LeaderWorkerSet v0.10.0 and KServe LLMInferenceService v0.21.0 on
OpenShift, plus an `oc mirror` config for disconnected installs.

**Argo CD is the deployment target: one Application per chart directory**,
created by the user in production (this repo ships no Application manifests —
do not add any). Each chart therefore has to be self-sufficient: its CRDs in
`crds/`, every required setting a default in `values.yaml` (no required `-f`
overlay), and every ordering constraint inside it expressed as a sync wave. `README.md` is the user-facing doc. [`PATCHES.md`](PATCHES.md) is the
authoritative audit of every deviation from upstream and must be updated
whenever a chart value or added resource changes — run `hack/list-patches.sh`
and reconcile it. README's "Delta from the upstream charts" section is the
narrative version of the same thing; keep the two consistent.
[`UPGRADE.md`](UPGRADE.md) is the authoritative version-bump runbook.

```
charts/envoy-gateway-openshift/          wraps oci://docker.io/envoyproxy/gateway-helm v1.9.1
  crds/                                  GENERATED: gateway.envoyproxy.io + InferencePool (x2)
charts/envoy-ai-gateway-openshift/       wraps oci://docker.io/envoyproxy/ai-gateway-helm v1.1.0
  crds/                                  GENERATED: aigateway.envoyproxy.io
charts/lws-openshift/                    wraps oci://registry.k8s.io/lws/charts/lws v0.10.0
                                         (CRDs: upstream subchart's own crds/)
charts/kserve-llmisvc-openshift/         wraps oci://ghcr.io/kserve/charts/kserve-llmisvc-resources
                                         AND kserve-runtime-configs, both v0.21.0-rc1
  crds/                                  GENERATED: serving.kserve.io + llm-d.ai
  templates/llmisvcconfigs.yaml          the 13 presets, re-rendered at sync wave 10
hack/update-crds.sh                       regenerates charts/*/crds/ from the vendored charts; --check
hack/install-crds.sh                      plain-Helm only: applies the committed crds/; never Gateway API
hack/charts/                              vendored CRD-source charts, so update-crds.sh runs offline
hack/list-images.sh                       derives the mirror list from the charts; --check
hack/list-patches.sh                      derives every value change from the vendored subcharts
hack/resolve-digest.sh                    image digest without pulling
mirror-config.yaml                        oc mirror v2 ImageSetConfiguration
PATCHES.md                                audit report: every change from upstream
UPGRADE.md                                version-bump runbook + checklist
```

Disconnected is the target. Every upstream subchart and CRD chart is vendored in
the repo, and the generated CRDs are committed, so no step of the install path
needs a chart registry.

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
   `--skip-crds` (Argo CD: `skipCrds`) does protect but is not a value, and is
   all-or-nothing so it would also skip this repo's own `crds/`. Helm does
   not template `crds/`, so no value can gate the Gateway API files
   selectively — that is why upstream's separate `gateway-crds-helm` chart
   (CRDs in `templates/`, hence gateable) is the sanctioned source, rendered
   into the wrapper's `crds/` by `hack/update-crds.sh`.

2. **Gateway API CRDs are never created, patched or deleted here.** They belong
   to `cluster-ingress-operator`. `hack/update-crds.sh` refuses to write one
   into any `crds/`; `hack/install-crds.sh` asserts afterwards that it did not
   become a field manager on one.

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

6. **Every CRD ships inside its chart's `crds/`, generated — never hand-edited.**
   `hack/update-crds.sh` renders them from the vendored upstream charts
   (versions read from the wrappers' `Chart.yaml`), filters by API group, and
   splices in exactly two annotations: `argocd.argoproj.io/sync-wave: "-10"`
   and `argocd.argoproj.io/sync-options: ServerSideApply=true,Prune=false,Delete=false`.
   Run it on every version bump; `--check` fails on drift. Rules:
   * **One file per CRD.** Helm refuses any chart file over 5 MiB
     (`MaxDecompressedFileSize`, present in Helm 3.17.3 and 4.x); the
     `serving.kserve.io` CRDs are 5.4 MB together.
   * **`crds/`, never `templates/`.** `templates/` would put CRDs under Helm
     ownership (deleted on `helm uninstall`) and through Go templating.
     `kserve-llmisvc-resources` renders the GIE/llm-d CRDs into `templates/`
     behind `createGIECRDs` — keep it `false`; `_validate.tpl` enforces it.
   * **InferencePool CRDs live in `envoy-gateway-openshift`**, not the kserve
     chart: Envoy Gateway watches that kind from startup (`backendResources`)
     and its Application syncs first.
   * **LWS is the exception**: upstream already ships its 3 CRDs in the
     subchart's `crds/`, ungated, so the wrapper passes them through and
     `update-crds.sh` does not generate them (a copy would render each twice).
     They carry no wave and no `Delete=false`.
   * Argo CD applies `crds/` on every sync. Plain `helm upgrade` never does, so
     the plain-Helm path still needs `hack/install-crds.sh` on every bump.

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
    `helm lint` must be run with `-n kserve` for that chart. Likewise
    `lws-openshift` must deploy to `lws-system`: its CRD hardcodes
    `lws-webhook-service.lws-system` — which is also why LWS cannot be folded
    into the kserve chart (one Application, one namespace).

11. **The KServe presets must stay at a later sync wave than the controller.**
    The 13 `LLMInferenceServiceConfig` CRs are rejected by the controller's
    `failurePolicy: Fail` ValidatingWebhookConfiguration until the controller
    pod is Ready. Neither upstream chart can annotate them, so the subchart's
    own copy stays off (`kserve-runtime-configs.kserve.llmisvcConfigs.enabled:
    false`) and `templates/llmisvcconfigs.yaml` re-renders the subchart's own
    `files/llmisvcconfigs/resources.yaml` — read via `.Subcharts` — with
    `argocd.syncWave.runtimeConfigs` ("10"). Output must stay identical to
    upstream's apart from that annotation. `_validate.tpl` fails if both are
    on. Plain Helm has no waves: first install with
    `runtimeConfigs.enabled=false`, then upgrade.

12. **The two KServe-required settings are defaults, not overlays.**
    `envoy-gateway.config.envoyGateway.extensionManager.backendResources`
    (InferencePool) in `charts/envoy-gateway-openshift/values.yaml` — else
    Envoy Gateway rejects the `InferencePool` backendRef and serves a **500
    direct response** on every model route — and
    `gateway.listener.allowedRoutes.namespaces.from: All` in
    `charts/envoy-ai-gateway-openshift/values.yaml` — else model `HTTPRoute`s
    are `NotAllowedByListeners`. Likewise
    `ai-gateway.controller.mutatingWebhook.certManager.enable: true`, without
    which the AI Gateway render is non-deterministic under Argo CD (`lookup`
    has no cluster) and the Application is permanently OutOfSync. Do not move
    any of these back into `-f` files: an Application pointed at a chart
    directory must be correct with no value files.

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

16. **Sync waves, per chart — keep this order.** Helm hooks map to Argo CD
    `PreSync` with the hook weight, so the SCC RoleBinding hooks (invariant 4)
    need no wave annotation of their own; do not add one.
    * envoy-gateway: PreSync hooks; CRDs -10; everything else 0.
    * envoy-ai-gateway: CRDs -10; SCC binding -5; controller/EnvoyProxy 0;
      GatewayClass 1; **Gateway 2** (after the AI Gateway controller is
      healthy — this replaces the plain-Helm `oc rollout restart
      deploy/envoy-gateway`); Route 3.
    * lws: everything 0 (upstream CRDs included; nothing creates LWS objects).
    * kserve-llmisvc: PreSync SCC hook; CRDs -10; controller 0; **presets 10**.
    Across Applications (the user's to set): envoy-gateway → envoy-ai-gateway
    and lws → kserve-llmisvc.

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
2. **The CRDs in `charts/*/crds/` are generated** — run `hack/update-crds.sh`
   on every bump (`--check` catches a forgotten run). Argo CD then applies
   them on sync; plain `helm upgrade` never touches `crds/`, so that path also
   needs `hack/install-crds.sh`.
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
  the committed defaults. (Under Argo CD they are in the Application's
  `valueFiles`, so this only bites plain Helm.)
* **`helm rollback` does not roll back CRDs** — Helm never updates `crds/`.
  After a rollback you are running old controllers against new CRD schemas.
  Reverting the git commit under Argo CD does roll them back, except a CRD the
  new version added (`Prune=false`).

## Verification sequence

Run all of it after any chart change. `helm lint` passing is not sufficient —
all three bugs found while building this (invalid uppercase resource names,
hook-ordering SCC failure, and the Route `targetPort` 503) passed lint. The
last one also passed a 404 smoke test, so **prove the data path forwards real
traffic**, not just that Envoy answers: apply a throwaway `HTTPRoute` with a
`RequestRedirect` filter and assert the 302 and its `Location` header. The
README's "Proving the data path forwards traffic" section has the manifest.

```bash
# Note -n kserve: the kserve chart refuses to render elsewhere (invariant 10).
helm lint charts/envoy-gateway-openshift charts/envoy-ai-gateway-openshift charts/lws-openshift
helm lint charts/kserve-llmisvc-openshift -n kserve

# Render exactly what Argo CD renders (--include-crds). Expected CRD counts:
# envoy-gateway 10, envoy-ai-gateway 6, lws 3, kserve 5. Every OTHER column 0:
# no Gateway API CRD, no admission policy, no uppercase name, no gateway-dev.
for c in envoy-gateway-openshift:envoy-gateway-system \
         envoy-ai-gateway-openshift:envoy-ai-gateway-system \
         lws-openshift:lws-system \
         kserve-llmisvc-openshift:kserve; do
  r="$(helm template x "charts/${c%%:*}" -n "${c##*:}" --include-crds)"
  printf '%-28s CRDs=%-3s gatewayAPI=%s VAP=%s uppercase=%s gateway-dev=%s\n' "${c%%:*}" \
    "$(grep -c '^kind: CustomResourceDefinition' <<<"$r")" \
    "$(grep -cE '^  group: gateway\.networking\.k8s\.io$' <<<"$r")" \
    "$(grep -c 'kind: ValidatingAdmissionPolicy' <<<"$r")" \
    "$(grep -E '^  name:' <<<"$r" | grep -c '[A-Z]')" \
    "$(grep -c 'gateway-dev' <<<"$r")"
done

# 13 presets, all at wave 10; the AI Gateway render must be deterministic
helm template x charts/kserve-llmisvc-openshift -n kserve \
  | grep -A3 '^kind: LLMInferenceServiceConfig' | grep -c 'sync-wave: "10"'   # 13
diff <(helm template x charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system) \
     <(helm template x charts/envoy-ai-gateway-openshift -n envoy-ai-gateway-system) && echo deterministic

# committed CRDs and mirror list must still match the vendored charts
./hack/update-crds.sh --check
./hack/list-images.sh --check
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

# the two KServe-required settings must be in effect (invariant 12)
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

For KServe, a green sync proves nothing about routing. Apply a
throwaway `LLMInferenceService` and assert three things — the README's
"Proving the KServe data path" section has the manifest and the commands:

1. the generated `HTTPRoute` is `Accepted=True` **and** `ResolvedRefs=True`
   (ResolvedRefs is the `InferencePool` backendRef resolving, i.e. proof that
   `backendResources` is in effect);
2. the Envoy config dump contains an `endpointpicker_*_ext_proc` cluster and
   **zero** routes with a 500 direct response;
3. the endpoint-picker pod logs show it processed the request.

On a GPU-less cluster the model pod stays in its `storage-initializer` init
container and the endpoint picker answers 400 — expected, not a wiring failure.

## Sync order matters

Under Argo CD (the target), the user creates one Application per chart. Across
Applications:

```
envoy-gateway-openshift      (ns envoy-gateway-system)     CRDs incl. InferencePool
  -> envoy-ai-gateway-openshift (ns envoy-ai-gateway-system)  needs EnvoyProxy CRD
  -> lws-openshift              (ns lws-system)              parallel with the above
  -> kserve-llmisvc-openshift   (ns kserve)                  needs LWS + InferencePool CRDs
```

Inside each chart the order is sync waves (invariant 16). Applications need
`ServerSideApply=true` and must NOT set `skipCrds`. `cert-manager` must exist
first (KServe and AI Gateway webhook certificates). README "Deploying with Argo
CD" has the full Application requirements.

Plain Helm (fallback): `hack/install-crds.sh` → envoy-gateway → envoy-ai-gateway
→ `oc rollout restart deploy/envoy-gateway` → lws → kserve-llmisvc with
`runtimeConfigs.enabled=false` → `helm upgrade` kserve-llmisvc. The restart and
the two-pass KServe install are what the Gateway's wave 2 and the presets'
wave 10 do under Argo CD.

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
  conflict (under Argo CD with selfHeal, the patch is simply reverted). Change
  values and upgrade/sync instead; if it already happened, delete the object
  and let Helm or Argo CD recreate it.
* **A wrapper can read a subchart's files via `.Subcharts.<name>.Files`**
  (Helm ≥3.10, verified on 3.17 and 4.1). That is how the kserve chart
  re-renders upstream's presets with a sync wave without copying or forking
  them. Prefer it over vendoring an upstream file.
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
* **Never hand-edit `charts/*/crds/`.** Those files are generated; change
  `hack/update-crds.sh` and regenerate. `--check` fails on any hand edit.
* **Never add Argo CD `Application` manifests to this repo.** The user creates
  them in production and points them at the chart directories; the README's
  "Deploying with Argo CD" section documents what they must set.
