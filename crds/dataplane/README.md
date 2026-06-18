# Dataplane CRDs (mirror)

Knative Serving CRDs consumed by the dataplane chart's optional zero-trust
gateway (Kourier + Envoy + activator + autoscaler), plus — once
[#401](https://github.com/unionai/helm-charts/pull/401) lands — the
Union-maintained `FlyteWorkflow` CRD.

**This directory is a mirror of [`charts/dataplane/crds/`](../../charts/dataplane/crds/),
not the source of truth.** The chart's `crds/` dir is what Helm 3
auto-installs on `helm install`; this top-level copy exists so a
dedicated ArgoCD `Application` (or `kubectl apply --server-side -f crds/dataplane/`)
can install the same CRDs with SSA when the customer opts out of
Helm-managed CRDs (`helm install --skip-crds`). Both paths apply
byte-identical YAML.

## Versions

| Source | Provides |
|---|---|
| `knative/serving` release `knative-<VERSION>/serving-crds.yaml` | 12 CRDs (`*.serving.knative.dev`, `*.networking.internal.knative.dev`, `*.autoscaling.internal.knative.dev`, `*.caching.internal.knative.dev`) |

`<VERSION>` is pinned in [`VERSION`](VERSION).

The two `*.operator.knative.dev` CRDs (`knativeservings`, `knativeeventings`)
that the previous `crds/knative-operator/` vendoring included are
**deliberately dropped**: the dataplane chart now installs Knative Serving
directly via the gateway templates rather than via the Knative Operator CR
pattern, so the operator CRDs are no longer needed.

## Refresh

```bash
# From repo root
vim crds/dataplane/VERSION   # bump e.g. v1.16.0 → v1.17.0
make vendor-crds             # re-pulls from upstream; writes to chart dir + mirror
make check-vendored-crds     # drift gate (also runs in CI)
git diff                     # review, then commit
```

[`scripts/sync.sh`](scripts/sync.sh) is the only thing that should write to
`crd-*.knative.dev.yaml` in either dir — hand edits are overwritten on the
next sync. Non-Knative CRDs in the chart dir (e.g. `crd-flyteworkflows.yaml`)
are preserved by name-pattern filtering. To patch a CRD downstream, use
kustomize on the ArgoCD source or a helm post-render.

## Why both locations

The Helm 3 `crds/` convention auto-installs on `helm install` and is great
for customers who want a single-command bootstrap. ArgoCD-managed installs
prefer `helm template --skip-crds` + a separate SSA apply for the CRDs,
because Helm's `crds/` dir is never modified by `helm upgrade` and because
SSA sidesteps the 256 KiB `last-applied-configuration` annotation limit
that large CRDs (Knative `services` clocks in around 110 KiB after schema
expansion, well into the danger zone if multiple CRDs end up under one
managed-field document) can hit on the client-side apply fallback path.
Shipping both lets the same chart support both install styles without
forking content.
