#!/usr/bin/env bash
#
# Prints every value this repo changes relative to the vendored upstream
# subchart defaults, derived from the charts rather than from documentation.
# This is the machine-checkable half of PATCHES.md -- run it after any version
# bump and reconcile the report with the output.
#
#   hack/list-patches.sh              # per-chart detail
#   hack/list-patches.sh --summary    # the counts table only
#
# Three categories:
#   OVERRIDE  the key exists upstream with a different value  <- the real delta
#   ADDED     the key does not exist in upstream's values.yaml
#   restated  the key exists upstream with the SAME value     <- no effect,
#             present only so the knob is visible without extracting the chart
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
command -v python3 >/dev/null 2>&1 || { echo "!! python3 not found" >&2; exit 1; }

MODE="${1:-detail}"
case "$MODE" in
  --summary) MODE=summary ;;
  ""|--detail) MODE=detail ;;
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "!! unknown argument: $MODE (try --help)" >&2; exit 2 ;;
esac

MODE="$MODE" python3 - <<'PY'
import yaml, tarfile, glob, os, sys

# wrapper dir, upstream subchart name, the values key it is passed under
CHARTS = [
 ("envoy-gateway-openshift",         "gateway-helm",              "envoy-gateway"),
 ("envoy-ai-gateway-openshift",      "ai-gateway-helm",           "ai-gateway"),
 ("lws-openshift",                   "lws",                       "lws"),
 ("kserve-llmisvc-openshift",        "kserve-llmisvc-resources",  "kserve-llmisvc-resources"),
 ("kserve-runtime-configs-openshift","kserve-runtime-configs",    "kserve-runtime-configs"),
]
mode = os.environ.get("MODE", "detail")

def leaves(x, p=""):
    o = {}
    if isinstance(x, dict):
        if not x:
            o[p] = {}
        for k, v in x.items():
            o.update(leaves(v, f"{p}.{k}" if p else k))
    elif isinstance(x, list):
        o[p] = x
    else:
        o[p] = x
    return o

def short(v, n=44):
    s = repr(v)
    return s if len(s) <= n else s[:n-3] + "..."

rows, detail, tot_o, tot_a = [], {}, 0, 0
for wrapper, sub, key in CHARTS:
    hits = glob.glob(f"charts/{wrapper}/charts/{sub}-*.tgz")
    if not hits:
        sys.exit(f"!! no vendored subchart for {wrapper} (run: helm dependency update charts/{wrapper})")
    up = yaml.safe_load(tarfile.open(hits[0]).extractfile(f"{sub}/values.yaml").read()) or {}
    ours = (yaml.safe_load(open(f"charts/{wrapper}/values.yaml")) or {}).get(key) or {}
    U, O = leaves(up), leaves(ours)
    over  = {k: (U[k], O[k]) for k in O if k in U and U[k] != O[k]}
    added = {k: O[k] for k in O if k not in U}
    same  = [k for k in O if k in U and U[k] == O[k]]
    rows.append((wrapper, os.path.basename(hits[0]), len(U), len(over), len(added), len(same)))
    detail[wrapper] = (over, added, same)
    tot_o += len(over); tot_a += len(added)

print(f"{'WRAPPER CHART':34} {'upstream':>9} {'OVERRIDE':>9} {'ADDED':>6} {'restated':>9}")
print("-" * 72)
for w, tgz, nu, no, na, ns in rows:
    print(f"{w:34} {nu:>9} {no:>9} {na:>6} {ns:>9}")
print("-" * 72)
print(f"{'TOTAL':34} {'':>9} {tot_o:>9} {tot_a:>6}")
print()
print("Vendored subcharts:")
for _, tgz, *_ in rows:
    print(f"  {tgz}")

if mode == "summary":
    raise SystemExit

print()
for wrapper, (over, added, same) in detail.items():
    print("=" * 72)
    print(wrapper)
    print("=" * 72)
    for k, (u, o) in sorted(over.items()):
        print(f"  OVERRIDE  {k}")
        print(f"            upstream: {short(u)}")
        print(f"            ours:     {short(o)}")
    for k, v in sorted(added.items()):
        print(f"  ADDED     {k} = {short(v)}")
    if same:
        print(f"  restated  {len(same)} key(s) at upstream's own value (no effect): "
              + ", ".join(sorted(same)[:4]) + (" ..." if len(same) > 4 else ""))
    if not (over or added):
        print("  no overrides, no additions -- upstream verbatim")
    print()
PY
