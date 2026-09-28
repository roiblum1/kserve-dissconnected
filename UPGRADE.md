# Upgrade procedure

How to move this stack to a new Envoy Gateway, Envoy AI Gateway, LeaderWorkerSet
or KServe release.

Current pins:

| Component | Version | Pinned in |
|---|---|---|
| Envoy Gateway (`gateway-helm`) | `v1.9.1` | `charts/envoy-gateway-openshift/Chart.yaml` |
| Envoy AI Gateway (`ai-gateway-helm`) | `v1.1.0` | `charts/envoy-ai-gateway-openshift/Chart.yaml` |
| Envoy data plane | `distroless-v1.39.1` | `charts/envoy-gateway-openshift/values.yaml` |
| LeaderWorkerSet (`lws`) | `v0.10.0` | `charts/lws-openshift/Chart.yaml` |
| KServe (`kserve-llmisvc-resources`) | `v0.21.0-rc1` | `charts/kserve-llmisvc-openshift/Chart.yaml` |
| KServe (`kserve-runtime-configs`) | `v0.21.0-rc1` | `charts/kserve-llmisvc-openshift/Chart.yaml` (same chart) |
| KServe CRDs (`kserve-llmisvc-crd`) | `v0.21.0-rc1` | `hack/charts/`; version read from the chart above by `hack/update-crds.sh` |
| Envoy Gateway / AI Gateway CRD charts | as their controllers | `hack/charts/`; versions read from the wrapper `Chart.yaml`s |
| Gateway API | `v1.4.1` standard | **not ours** — owned by `cluster-ingress-operator` |
| cert-manager | Operator `v1.20.0` | **not ours** — a prerequisite, not installed here |

> **KServe version labels.** `v0.21.0-rc1` *is* KServe 0.21.0: the v0.21.0
> GitHub release ships its chart tarballs still named `…-v0.21.0-rc1.tgz` and
> `ghcr.io/kserve/charts` has no `v0.21.0` tag. The `-rc1` OCI artifacts are
> byte-identical to the release's. On the next bump, check whether upstream has
> started publishing a final tag before assuming the `-rc` convention holds.

---

## The short version

Under Argo CD a bump is a git commit; the Applications pick it up on sync.

```bash
# 1. edit the dependency versions in charts/*-openshift/Chart.yaml   (§2)
# 2. replace the tarballs in charts/*/charts/ and hack/charts/        (§2)
# 3. regenerate the CRDs -- versions are read from Chart.yaml
./hack/update-crds.sh && git diff --stat -- 'charts/*/crds'
# 4. prove nothing drifted
./hack/update-crds.sh --check && ./hack/list-images.sh --check && ./hack/list-patches.sh
# 5. commit, push, let Argo CD sync (CRDs go first, at wave -10)
```

Everything below is what those five lines cannot check for you.

## The mental model

Upstream charts are vendored **byte-identical** and never forked, so the version
bump itself is a handful of lines. What actually needs attention is the things
that live *outside* the charts:

1. **Two image defaults compiled into the Envoy Gateway Go binary** — the data
   plane and the shutdown-manager. They never appear in `helm template`, so
   nothing will warn you when they change.
2. **CRDs.** They are generated files in each chart's `crds/`, so a bump that
   forgets `hack/update-crds.sh` ships new controllers with old schemas.
   `--check` catches it. Argo CD applies `crds/` on every sync; plain
   `helm upgrade` *never* does, so a Helm-managed install also needs
   `hack/install-crds.sh`.
3. **The AI Gateway ↔ Envoy Gateway extension-hook contract**, which upstream
   publishes as a values file in the ai-gateway repo, not in the chart. The
   `InferencePool` add-on lives in the same place.
4. **The CRD hazard**, which must be re-confirmed rather than assumed to be
   unchanged — for both Envoy Gateway's Gateway API CRDs and KServe's
   `createGIECRDs`.
5. **Six images hardcoded in KServe's presets**, unreachable by any Helm value,
   so they can only be redirected by the mirror map. They change with the KServe
   version, which is why `hack/list-images.sh --check` is part of the procedure
   rather than an optional nicety.
6. **KServe's own dependency pins**, published in the release's
   `llmisvc-dependency-install.sh`. That file is the authoritative statement of
   what KServe expects, including which Envoy Gateway version it was tested
   against.

Everything else is `helm dependency update`.

---

## 1. Check compatibility first

```bash
EG_NEW=v1.10.0            # the Envoy Gateway version you are moving to
AIGW_NEW=v1.2.0           # the Envoy AI Gateway version you are moving to
LWS_NEW=v0.11.0           # the LeaderWorkerSet version you are moving to
KSERVE_NEW=v0.22.0-rc0    # the KServe chart tag you are moving to
```

**Start from KServe's own dependency matrix**, not from the newest release of
each component. The KServe release publishes exactly what it was tested against:

```bash
curl -sfL "https://github.com/kserve/kserve/releases/download/${KSERVE_NEW%-rc*}/llmisvc-dependency-install.sh" \
  | grep -E '^(CERT_MANAGER|ENVOY_GATEWAY|ENVOY_AI_GATEWAY|LWS|GATEWAY_API|GIE|LLMD_ROUTER|KSERVE)_VERSION='
```

For v0.21.0 that prints:

```
CERT_MANAGER_VERSION=v1.17.0
ENVOY_GATEWAY_VERSION=v1.8.1
ENVOY_AI_GATEWAY_VERSION=v1.1.0
LWS_VERSION=v0.10.0
GATEWAY_API_VERSION=v1.5.1
GIE_VERSION=v1.5.0
LLMD_ROUTER_VERSION=v0.10.0
KSERVE_VERSION=v0.21.0
```

**KServe leads the versions.** Follow every one of those pins unless there is a
recorded reason not to. `LWS_VERSION` in particular: bump
`charts/lws-openshift` to whatever KServe pins, not to the newest LWS release.

Two are not followed, both forced rather than chosen:

* **`GATEWAY_API_VERSION`** — owned by `cluster-ingress-operator`, never ours.
* **`ENVOY_GATEWAY_VERSION`** — we run v1.9.1, not v1.8.1. v1.8.1 watches the
  experimental `ListenerSet` kind unconditionally and crash-loops on a
  standard-channel cluster. **Re-test this on every KServe bump**, because the
  moment KServe pins v1.9.x or later the exception should be dropped:

  ```bash
  # does the pinned version probe for ListenerSet before watching it?
  curl -fsSL "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_NEW/internal/provider/kubernetes/controller.go" \
    | sed -n '/^type gatewayAPIReconciler struct/,/^}/p' \
    | grep -c listenerSetCRDExists        # 1 = safe on standard channel, 0 = will crash-loop
  ```

  If that prints `0`, do not bump to it, whatever KServe pins. Record the
  decision in README's "Why Envoy Gateway is v1.9.1 and not KServe's v1.8.1".

Also check whether the OCI chart tag exists at all before bumping, because
KServe's release tag and its chart tag have diverged before:

```bash
helm show chart oci://ghcr.io/kserve/charts/kserve-llmisvc-resources --version "$KSERVE_NEW" | head -5
```

**AI Gateway's minimum Envoy Gateway version.** AI Gateway states this in its
prerequisites page, and it has moved between releases:

```bash
# https://aigateway.envoyproxy.io/docs/getting-started/prerequisites/
curl -sfL "https://raw.githubusercontent.com/envoyproxy/ai-gateway/$AIGW_NEW/manifests/envoy-gateway-values.yaml" \
  | head -30
```

**Kubernetes / OpenShift version.** Envoy AI Gateway v1.1.0 required Kubernetes
1.32+. Check the new release notes; this cluster is on 1.35.

**Gateway API.** Compare what the new Envoy Gateway builds against with what the
cluster actually serves:

```bash
curl -sfL "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_NEW/go.mod" | grep 'sigs.k8s.io/gateway-api'
oc get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='cluster: {.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} / {.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
```

A gap is normal and usually fine — Envoy Gateway probes for each optional CRD at
startup and disables the watches it cannot satisfy. See
[Gateway API version compatibility](README.md#gateway-api-version-compatibility)
in the README for the field-level analysis and how to redo it. What matters is
that the new Envoy Gateway does not *require* a kind or field the cluster lacks.

---

## 2. Bump the pins and re-vendor

Only bump what you actually mean to; each chart is independent. The two KServe
subcharts live in the same `Chart.yaml` and move together — the `-g` does both.

```bash
sed -i '' "s/version: v1.9.1/version: $EG_NEW/"   charts/envoy-gateway-openshift/Chart.yaml
sed -i '' "s/version: v1.1.0/version: $AIGW_NEW/" charts/envoy-ai-gateway-openshift/Chart.yaml
sed -i '' "s/v0.10.0/$LWS_NEW/g"                  charts/lws-openshift/Chart.yaml
sed -i '' "s/v0.21.0-rc1/$KSERVE_NEW/g"           charts/kserve-llmisvc-openshift/Chart.yaml

for c in charts/*-openshift; do helm dependency update "$c"; done
```

`appVersion` is also in each `Chart.yaml`, and `lws-openshift/values.yaml` pins
`lws.image.manager.tag` — the `-g` on those two `sed`s covers both.

Re-vendor the CRD-source charts too. `hack/update-crds.sh` renders every
chart's `crds/` from them, looking each one up by the version in the wrapper's
`Chart.yaml`, so they must move with the pins:

```bash
rm -f hack/charts/*.tgz
helm pull oci://docker.io/envoyproxy/gateway-crds-helm     --version "$EG_NEW"     -d hack/charts
helm pull oci://docker.io/envoyproxy/ai-gateway-crds-helm  --version "$AIGW_NEW"   -d hack/charts
helm pull oci://ghcr.io/kserve/charts/kserve-llmisvc-crd   --version "$KSERVE_NEW" -d hack/charts
```

Then regenerate the CRDs and review what upstream changed:

```bash
./hack/update-crds.sh
git diff --stat -- 'charts/*/crds'      # new, removed, changed CRDs
git diff -- 'charts/*/crds' | less      # the schema changes themselves
```

A CRD upstream **dropped** disappears from git but, thanks to its
`Prune=false` annotation, not from the cluster — delete it by hand once
nothing uses it. A **new** CRD needs no action: the script picks up everything
in the listed API groups. A **new API group** does: add it to the relevant
`split_crds` call in `hack/update-crds.sh` (and the `grep -E` in
`hack/install-crds.sh`).

Confirm the vendored charts are unmodified upstream artifacts:

```bash
TMP=$(mktemp -d)
helm pull oci://docker.io/envoyproxy/gateway-helm                 --version "$EG_NEW"     -d "$TMP"
helm pull oci://docker.io/envoyproxy/ai-gateway-helm              --version "$AIGW_NEW"   -d "$TMP"
helm pull oci://registry.k8s.io/lws/charts/lws                    --version "$LWS_NEW"    -d "$TMP"
helm pull oci://ghcr.io/kserve/charts/kserve-llmisvc-resources    --version "$KSERVE_NEW" -d "$TMP"
helm pull oci://ghcr.io/kserve/charts/kserve-runtime-configs      --version "$KSERVE_NEW" -d "$TMP"
shasum -a 256 "$TMP"/*.tgz charts/*/charts/*.tgz | sort -k1,1
rm -rf "$TMP"
```

Each vendored digest must appear twice.

---

## 3. Diff upstream's values against the previous release

This is the step that catches renamed, removed or newly-required settings —
including whether the keys this chart overrides still exist and still mean the
same thing.

```bash
python3 - <<'PY'
import yaml, tarfile, subprocess, tempfile, os, glob
OLD, NEW = "v1.9.1", os.environ.get("EG_NEW", "v1.10.0")
CHART = "gateway-helm"
d = tempfile.mkdtemp()
for v in (OLD, NEW):
    subprocess.run(["helm","pull",f"oci://docker.io/envoyproxy/{CHART}",
                    "--version",v,"-d",d], check=True, capture_output=True)
def vals(v):
    t = tarfile.open(glob.glob(f"{d}/{CHART}-{v}.tgz")[0])
    return yaml.safe_load(t.extractfile(f"{CHART}/values.yaml").read())
def leaves(x, p=""):
    o = {}
    if isinstance(x, dict):
        if not x: o[p] = {}
        for k, v in x.items(): o.update(leaves(v, f"{p}.{k}" if p else k))
    elif isinstance(x, list): o[p] = x
    else: o[p] = x
    return o
a, b = leaves(vals(OLD)), leaves(vals(NEW))
print(f"--- {CHART} {OLD} -> {NEW} ---")
print("\nREMOVED (break us if we set them):")
for k in sorted(set(a) - set(b)): print("  -", k)
print("\nADDED (review for new required settings):")
for k in sorted(set(b) - set(a)): print("  +", k)
print("\nDEFAULT CHANGED:")
for k in sorted(set(a) & set(b)):
    if a[k] != b[k]: print(f"  ~ {k}: {a[k]!r} -> {b[k]!r}")
PY
```

Then confirm every chart's own overrides still land on real keys:

```bash
helm template x charts/envoy-gateway-openshift            -n envoy-gateway-system    >/dev/null && echo "eg OK"
helm template x charts/envoy-ai-gateway-openshift         -n envoy-ai-gateway-system >/dev/null && echo "aigw OK"
helm template x charts/lws-openshift                      -n lws-system              >/dev/null && echo "lws OK"
helm template x charts/kserve-llmisvc-openshift           -n kserve                   >/dev/null && echo "kserve OK"
# 13 presets, rendered by the wrapper from kserve-runtime-configs' own file.
# 0 means the subchart moved files/llmisvcconfigs/resources.yaml -- the
# template fails loudly in that case, but check the count anyway.
helm template x charts/kserve-llmisvc-openshift -n kserve | grep -c '^kind: LLMInferenceServiceConfig'
```

`helm template` rendering is necessary but not sufficient: Helm silently accepts
a value whose key upstream has renamed. The keys that must still exist:

| Chart | Keys we override |
|---|---|
| `gateway-helm` | `crds.enabled`, `global.images.envoyProxy.image` |
| `ai-gateway-helm` | `controller.mutatingWebhook.certManager.enable` (and `controller.mutatingWebhook.namespaceSelector`, added where upstream has no key) |
| `lws` | *(none)* |
| `kserve-llmisvc-resources` | `kserve.llmisvc.createGIECRDs`, `kserve.llmisvc.controller.image`, `kserve.llmisvc.controller.imagePullPolicy`, `kserve.storage.image`, `kserve.controller.gateway.ingressGateway.kserveGateway` |
| `kserve-runtime-configs` | *(none — but `kserve.llmisvcConfigs.enabled` must still exist and default to `false`, and `files/llmisvcconfigs/resources.yaml` must still be where `templates/llmisvcconfigs.yaml` reads it)* |

A quick way to prove a key is still real rather than silently ignored — set it
to a sentinel and look for the sentinel in the output:

```bash
helm template x charts/kserve-llmisvc-openshift -n kserve \
  --set kserve-llmisvc-resources.kserve.storage.image=SENTINEL \
  | grep -c SENTINEL        # must be > 0
```

Re-run the values-diff script for each chart by changing `CHART`, the registry
and the two versions:

| `CHART` | registry |
|---|---|
| `gateway-helm` | `oci://docker.io/envoyproxy` |
| `ai-gateway-helm` | `oci://docker.io/envoyproxy` |
| `lws` | `oci://registry.k8s.io/lws/charts` |
| `kserve-llmisvc-resources` | `oci://ghcr.io/kserve/charts` |
| `kserve-runtime-configs` | `oci://ghcr.io/kserve/charts` |

For `kserve-llmisvc-resources`, pay particular attention to anything under
`kserve.llmisvc.controller.*securityContext*`: a new fixed UID or `fsGroup`
there changes which SCC is required.

Also re-check whether any previously-needed override has become redundant.
Two were removed that way, each after measuring rather than reasoning: the AI
Gateway image tags (upstream's defaults render the identical reference) and the
Envoy Gateway control-plane image. The test is to delete the override and diff
the render:

```bash
# Strip the fields that are regenerated on every render. With certManager
# enabled (the default here) ai-gateway-helm's render is deterministic, but a
# `--set` that turns it off brings back a fresh self-signed certificate per
# render, and a naive diff would then ALWAYS differ.
render() {
  helm template a "charts/$1" -n "$2" "${@:3}" \
    | grep -vE '^[[:space:]]+(tls\.crt|tls\.key|ca\.crt|caBundle):'
}
diff <(render <chart> <ns>) <(render <chart> <ns> --set <the.key>=null) \
  && echo "override is redundant -- remove it"
```

For an image pin specifically, the narrow comparison is clearer and immune to
that problem:

```bash
imgs() { grep -oE '(image: |--extProcImage=)\S+' | sort -u; }
C=charts/envoy-ai-gateway-openshift; N=envoy-ai-gateway-system

diff <(helm template a $C -n $N | imgs) \
     <(helm template a $C -n $N --set ai-gateway.controller.image.tag=null | imgs) \
  && echo "the pin changes nothing"
```

(Write it as `diff <(...) <(...)`, not a `for f in "" "--set ..."` loop —
zsh does not word-split an unquoted variable, so the flags arrive as a single
argument and `helm` rejects them.)

Note the inverse does **not** work: you cannot *remove* a key from a subchart's
map default through parent values. Helm merges the parent into the subchart
default, so `key: null` — and even restating the whole map without the key —
leaves the subchart's value in place. Verified on
`kserve.llmisvc.controller.containerSecurityContext.runAsUser`. If you need a
subchart key gone, the only options are an SCC binding, a post-render hook, or
forking the template.

---

## 4. Re-derive the image defaults that live in Go source

**Do not skip this.** These are compiled into the Envoy Gateway binary and are
invisible to Helm. The shutdown-manager default has historically been a mutable
`gateway-dev:latest` dev tag.

```bash
curl -sfL "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_NEW/api/v1alpha1/shared_types.go" \
  | grep -E 'DefaultEnvoyProxyImage|DefaultShutdownManagerImage|DefaultRateLimitImage'
```

Update both of these in `charts/envoy-gateway-openshift/values.yaml`:

| Value | Purpose |
|---|---|
| `envoy-gateway.global.images.envoyProxy.image` | the new `DefaultEnvoyProxyImage`, digest included |
| `envoy-gateway.config.envoyGateway.provider.kubernetes.shutdownManager.image` | the **release** image `docker.io/envoyproxy/gateway:$EG_NEW`, never `gateway-dev:latest` |

Also update the mirror overlays in `charts/*/values-mirror.yaml`.

KServe has no equivalent hidden default — its controller and
storage-initializer images are ordinary chart values — but the **preset**
images are worse: they are literals in upstream's
`files/llmisvcconfigs/resources.yaml` with no value hook at all. They change
with the KServe version and are only visible by rendering the chart:

```bash
helm template rc charts/kserve-llmisvc-openshift -n kserve \
  | grep -oE 'image: \S+' | sort -u
```

Whatever that prints must end up in `mirror-config.yaml`; step 7 checks it
mechanically.

---

## 5. Re-confirm the CRD hazard

The reason `crds.enabled` is `false` is specific and could change upstream — so
re-check it rather than assuming.

```bash
helm pull oci://docker.io/envoyproxy/gateway-helm --version "$EG_NEW" --untar -d /tmp
# Is the bundled Gateway API still experimental channel?
grep -m2 -E 'bundle-version|channel' /tmp/gateway-helm/charts/crds/crds/gatewayapi-crds.yaml
# Does the safe-upgrades ValidatingAdmissionPolicy still ship?
ls /tmp/gateway-helm/charts/crds/templates/
# Did new knobs appear that would let us gate Gateway API CRDs selectively?
cat /tmp/gateway-helm/charts/crds/values.yaml
```

Keep `crds.enabled: false` unless **all** of these become true:

* the bundled Gateway API CRDs are standard channel and ≤ the cluster's version, **and**
* the `safe-upgrades` admission policy is gone or off by default, **and**
* a value exists to exclude the Gateway API CRDs while keeping
  `gateway.envoyproxy.io`.

That last condition is the hard one: Helm does not template the `crds/`
directory, so it cannot be gated from values. If upstream ever adds such a knob,
this chart's delta can shrink further — that is the one change worth watching
for.

> Do **not** try to solve this with `--skip-crds` or by trusting Helm to skip
> existing CRDs. On Helm 4.3.0, `helm install` **overwrites** existing `crds/`
> content via server-side apply, despite the `--skip-crds` help text saying CRDs
> are "installed if not already present" (that was Helm 3). `--skip-crds` is a
> CLI flag rather than a value and is all-or-nothing, so it would also skip
> Envoy Gateway's own CRDs. See
> [README](README.md#why-not-just-crdsenabledtrue-or---skip-crds).

### KServe's CRD hazard

Separate mechanism, same consequence. `kserve.llmisvc.createGIECRDs` renders
four cluster-scoped CRDs into `templates/`, where Helm owns them and
`helm uninstall` **deletes** them — along with every `InferencePool` on the
cluster. Confirm the knob and the CRD set still look the same:

Render the **vendored subchart directly** — going through the wrapper is
blocked by its own guard, which is the point:

```bash
helm template x charts/kserve-llmisvc-openshift/charts/kserve-llmisvc-resources-*.tgz \
  -n kserve --set kserve.llmisvc.createGIECRDs=true \
  | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "CustomResourceDefinition":
        print(d["spec"]["group"], "/", d["metadata"]["name"])
'
```

For v0.21.0-rc1 that prints:

```
llm-d.ai / inferencemodelrewrites.llm-d.ai
llm-d.ai / inferenceobjectives.llm-d.ai
inference.networking.k8s.io / inferencepools.inference.networking.k8s.io
inference.networking.x-k8s.io / inferencepools.inference.networking.x-k8s.io
```

If the group list changed, update the `split_crds` group arguments in
`hack/update-crds.sh` — the script fails loudly if nothing matches, so a rename
cannot pass silently. InferencePool groups go to the envoy-gateway chart (Envoy
Gateway watches that kind from startup), `llm-d.ai` to the kserve chart.

Keep `createGIECRDs: false`. `templates/_validate.tpl` in that chart enforces
it, so flipping it back fails the render rather than the cluster.

### LWS's CRD hazard

`lws` ships its CRDs in its own `crds/`, which the wrapper passes through
unmodified — Argo CD applies them on every sync (no wave, no `Delete=false`).
With plain Helm, `helm upgrade` never updates them, so `hack/install-crds.sh`
does. Check the group set is unchanged:

```bash
# two-space indent only: spec.group, not the nested group: fields in the schemas
helm show crds charts/lws-openshift | grep -E '^  group:' | sort -u
#   group: disaggregatedset.x-k8s.io
#   group: leaderworkerset.x-k8s.io
```

Also check the leaderworkersets CRD's conversion webhook still points at
`lws-system` — that is why the lws Application's namespace is fixed:

```bash
helm show crds charts/lws-openshift | grep -A3 'service:' | grep namespace
```

---

## 6. Re-diff the AI Gateway extension-hook contract

The `extensionManager` block wiring Envoy Gateway to AI Gateway comes from
upstream's own values file. The hook list can change between AI Gateway
releases, and a stale list silently breaks xDS translation.

```bash
curl -sfL "https://raw.githubusercontent.com/envoyproxy/ai-gateway/$AIGW_NEW/manifests/envoy-gateway-values.yaml"
```

Compare its `config.envoyGateway.extensionManager` and `extensionApis` sections
against `charts/envoy-gateway-openshift/values.yaml` and reconcile any
difference — especially `hooks.xdsTranslator.post` and the `translation.*`
`includeAll` flags.

The `InferencePool` add-on lives beside it and is the
`extensionManager.backendResources` block in
`charts/envoy-gateway-openshift/values.yaml`, re-keyed under `envoy-gateway:`.
Diff that too:

```bash
curl -sfL "https://raw.githubusercontent.com/envoyproxy/ai-gateway/$AIGW_NEW/examples/inference-pool/envoy-gateway-values-addon.yaml"
```

In particular the `group`/`version` of the `InferencePool` entry: the Gateway
API Inference Extension has already moved from `inference.networking.x-k8s.io`
to `inference.networking.k8s.io/v1`, and if the add-on names a group whose CRD
is not installed, Envoy Gateway logs a failed watch on every reconcile and the
`HTTPRoute`s never resolve. Confirm against the CRDs the same chart ships:

```bash
ls charts/envoy-gateway-openshift/crds/ | grep inferencepools
```

Also confirm the field still exists in the Envoy Gateway API you are moving to:

```bash
curl -sfL "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_NEW/api/v1alpha1/envoygateway_types.go" \
  | grep -A4 'BackendResources'
```

---

## 7. Refresh `mirror-config.yaml`

The image list is **derived from the charts**, so this step is mostly running a
check rather than editing by hand:

```bash
./hack/list-images.sh --check
```

If it fails it prints the difference. Add or remove the named entries in
`mirror-config.yaml`, then refresh the digest comments:

```bash
./hack/list-images.sh --annotate
```

`--check` compares on `repo:tag` and ignores digests, because the charts pin
some references by digest while the mirror entries use tags. Mirroring a tag
copies the manifest it points at, so a digest-pinned reference still resolves
against the mirror.

Things that change here on a KServe bump and nowhere else:

* the two `docker.io/kserve/*` tags follow `kserve.version`;
* the **six preset images** (`ghcr.io/llm-d/*`, `docker.io/vllm/*`) are
  hardcoded upstream and move independently of the KServe version — v0.20.0
  used `llm-d-uds-tokenizer:vllm-v0.19.1` for the tokenizer where v0.21.0 uses
  `vllm/vllm-openai-cpu:v0.23.0`. No Helm value reaches them, so getting them
  into the mirror map is the only way they resolve on a disconnected cluster;
* `registry.k8s.io/lws/lws` follows whatever LWS version KServe pins.

Also re-check the cert-manager operator entry if the cluster's OpenShift minor
version changed — the catalog image is version-tagged
(`redhat-operator-index:v4.22`).

In a disconnected environment, **mirror before upgrading**, and apply the
regenerated `ImageDigestMirrorSet` before the rollout:

```bash
oc mirror -c mirror-config.yaml file://mirror --v2
# move mirror/ across, then
oc mirror -c mirror-config.yaml --from file://mirror docker://REGISTRY.EXAMPLE.COM --v2
oc apply -f working-dir/cluster-resources/idms-oc-mirror.yaml
oc apply -f working-dir/cluster-resources/itms-oc-mirror.yaml
```

Otherwise the rollout stalls in `ImagePullBackOff`. Note the charts are **not**
mirrored — they are vendored in this repository, refreshed in step 2.

---

## 8. Pre-flight, then apply

```bash
# Pre-flight. Note -n kserve: the kserve chart refuses to render elsewhere.
helm lint charts/envoy-gateway-openshift charts/envoy-ai-gateway-openshift charts/lws-openshift
helm lint charts/kserve-llmisvc-openshift -n kserve
./hack/update-crds.sh --check
./hack/list-images.sh --check
```

**Argo CD:** commit and push. Sync the Applications in the usual order —
`envoy-gateway`, then `envoy-ai-gateway` and `lws`, then `kserve-llmisvc`. In
each, the new CRDs are applied at wave -10 before the controllers that need
them, the Gateway waits for the AI Gateway controller, and the KServe presets
wait for the KServe controller. Nothing else to remember: every required value
is a default, so there are no `-f` flags to lose. Review the diff in the Argo
CD UI before syncing a CRD change; `Prune=false` means a CRD upstream removed
shows as "requires pruning" and stays.

**Plain Helm:** order matters, and the CRD step is not optional.

```bash
./hack/install-crds.sh --dry-run
# CRDs first: helm upgrade never touches them.
./hack/install-crds.sh

helm upgrade envoy-gateway charts/envoy-gateway-openshift \
  -n envoy-gateway-system --wait --timeout 6m
helm upgrade envoy-ai-gateway charts/envoy-ai-gateway-openshift \
  -n envoy-ai-gateway-system --wait --timeout 5m

# Envoy Gateway must reconnect to the AI Gateway xDS hook
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
oc rollout status  -n envoy-gateway-system deployment/envoy-gateway

helm upgrade lws charts/lws-openshift -n lws-system --wait --timeout 5m

# On an UPGRADE the controller's webhook is already serving, so the presets
# go in the same release, in one pass.
helm upgrade kserve-llmisvc charts/kserve-llmisvc-openshift \
  -n kserve --wait --timeout 6m
```

Add `-f charts/<chart>/values-mirror.yaml` or `values-loadbalancer.yaml` if the
original install used them — Helm does not remember `-f` flags, though nothing
required lives in an overlay any more.

Existing `LLMInferenceService` objects are **not** re-reconciled by a preset
change on their own. After a KServe bump, force one:

```bash
oc get llminferenceservice -A
oc annotate llminferenceservice <name> -n <ns> kserve.io/force-reconcile="$(date +%s)" --overwrite
```

---

## 9. Verify

Run the full suite from
[CLAUDE.md § Verification sequence](CLAUDE.md#verification-sequence). `helm lint`
passing is not sufficient — all three bugs found while building these charts
passed lint, and one of them also passed a 404 smoke test.

Minimum after any upgrade:

```bash
# correct SCC per namespace, no restarts. nonroot-v2 everywhere except
# lws-system, which is restricted-v2 by design.
for ns in envoy-gateway-system envoy-ai-gateway-system kserve lws-system; do
  echo "== $ns"
  oc get pods -n $ns -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc'
done

# the two KServe-required settings are in effect
oc get cm envoy-gateway-config -n envoy-gateway-system \
  -o jsonpath='{.data.envoy-gateway\.yaml}' | grep -A3 backendResources
oc get gateway envoy-ai-gateway -n envoy-ai-gateway-system \
  -o jsonpath='{.spec.listeners[*].allowedRoutes.namespaces.from}{"\n"}'   # All

oc get llminferenceserviceconfig -n kserve --no-headers | wc -l   # 13
oc get certificate llmisvc-serving-cert -n kserve                 # READY=True

# shutdown-manager must not be gateway-dev:latest
oc get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'

oc get gateway -n envoy-ai-gateway-system                      # PROGRAMMED=True
oc logs -n envoy-gateway-system deploy/envoy-gateway --tail=2000 | grep -ciE '"level":"error"|	error	'

# the shared cluster is still intact
oc get crd gateways.gateway.networking.k8s.io --show-managed-fields \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager} {end}{"\n"}'   # no helm, no envoy-ai-stack
oc get co ingress -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
```

Then **prove the data path forwards real traffic**, not just that Envoy answers
— see
[README § Proving the data path forwards traffic](README.md#proving-the-data-path-forwards-traffic),
and for KServe
[README § Proving the KServe data path](README.md#proving-the-kserve-data-path).
The KServe test is the one that catches a lost `backendResources` setting: it
asserts the generated `HTTPRoute` is `ResolvedRefs=True` and that no route is
serving a 500.

---

## 10. Rollback

**Argo CD:** revert the commit (or point `targetRevision` back) and sync. That
rolls back the CRDs too — they are ordinary manifests in the chart — with one
caveat: a CRD the new version *added* stays on the cluster (`Prune=false`).

**Plain Helm:**

```bash
helm rollback kserve-llmisvc         -n kserve
helm rollback lws                    -n lws-system
helm rollback envoy-ai-gateway       -n envoy-ai-gateway-system
helm rollback envoy-gateway          -n envoy-gateway-system
oc rollout restart -n envoy-gateway-system deployment/envoy-gateway
```

**`helm rollback` does not roll back CRDs** — Helm never updates `crds/`.
After rolling back a chart you are running old controllers against new CRD
schemas. That is normally fine, because CRD changes are additive, but it breaks
if the new CRDs dropped or narrowed a field the old controller writes. To revert
CRDs, check out the old commit's `charts/*/crds/` and re-apply them:

```bash
git checkout <old-commit> -- 'charts/*/crds' charts/lws-openshift/charts
./hack/install-crds.sh
```

Never `oc delete crd` to "clean up" — that deletes every object of that type
cluster-wide.

---

## What needs an uninstall, not an upgrade

Kubernetes treats `Deployment.spec.selector.matchLabels` as immutable, and this
chart's labels feed it. So a change to any of these is **not** an in-place
upgrade — it fails with `field is immutable` and needs
`helm uninstall` + `helm install`:

* the dependency `alias` in `Chart.yaml`
* `envoy-gateway.nameOverride` (currently `gateway-helm`, deliberately matching
  upstream so an in-place upgrade from a plain `gateway-helm` release stays
  possible)
* `envoy-gateway.fullnameOverride`

The LWS and KServe charts have no alias and no `nameOverride` — their upstream
chart names are already lowercase and DNS-safe — so they have nothing in this
category. Do not add one.

Also needing uninstall rather than upgrade:

* moving `kserve-llmisvc-openshift` to a different namespace. It will not
  render outside `kserve` anyway (`openshift.enforceNamespace`), but the CRD's
  hardcoded webhook namespace is the real constraint.
* changing `kserveGateway` to a Gateway in a different namespace: existing
  `HTTPRoute`s keep the old `parentRef` until each `LLMInferenceService` is
  re-reconciled. Force-annotate them, or delete and recreate them.

CRDs survive an uninstall — Helm never deletes `crds/` content, and Argo CD
honours the `Delete=false` on every CRD this repo generates (not on LWS's,
which come from upstream unannotated; see README, Uninstall). The same
immutable-selector rule applies under Argo CD: changing any of the names above
needs the old objects deleted, not a sync.

---

## Checklist

Compatibility

- [ ] KServe's `llmisvc-dependency-install.sh` read; each deviation is deliberate
- [ ] AI Gateway's minimum Envoy Gateway version satisfied
- [ ] Kubernetes/OpenShift version satisfied
- [ ] Gateway API gap reviewed; no newly-required kind or field missing
- [ ] `cert-manager` still present and healthy

Pins

- [ ] `Chart.yaml` pins bumped; both KServe subcharts at the same version
- [ ] `lws-openshift/values.yaml` image tag bumped with the chart
- [ ] `hack/charts/*.tgz` re-pulled
- [ ] `helm dependency update` run for every chart
- [ ] `hack/update-crds.sh` run; `git diff -- 'charts/*/crds'` reviewed; `--check` passes
- [ ] Vendored `.tgz` sha256 matches a fresh `helm pull` (each digest twice)

Values

- [ ] Upstream values diffed per chart; every overridden key still exists
- [ ] `hack/list-patches.sh` re-run and `PATCHES.md` reconciled with its output
- [ ] `DefaultEnvoyProxyImage` / `DefaultShutdownManagerImage` re-derived and pinned
- [ ] KServe preset images re-rendered and reviewed
- [ ] `crds.enabled` still `false`; KServe `createGIECRDs` still `false`
- [ ] AI Gateway `extensionManager` contract re-diffed
- [ ] `InferencePool` add-on re-diffed; group/version matches an installed CRD

Mirror

- [ ] `hack/list-images.sh --check` passes; digest comments refreshed
- [ ] cert-manager operator catalog tag matches the cluster's OpenShift minor
- [ ] Images mirrored and the IDMS/ITMS applied **before** the rollout

Apply

- [ ] Argo CD: Applications synced in order; diff reviewed before syncing CRD changes
- [ ] Plain Helm: `install-crds.sh --dry-run` clean, then applied; all four releases upgraded with the same optional overlays; Envoy Gateway restarted

Verify

- [ ] Correct SCC per namespace, 0 restarts
- [ ] Both KServe-required settings in effect (`backendResources`, `allowedRoutes: All`)
- [ ] Verification suite passed, including a real traffic test
- [ ] KServe data path proven: `HTTPRoute` `ResolvedRefs=True`, 0 routes serving 500
- [ ] Existing `LLMInferenceService` objects re-reconciled
- [ ] Gateway API CRDs still operator-owned; ingress operator not degraded
