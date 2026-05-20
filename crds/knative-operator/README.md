# Knative Operator CRDs

Required when App Serving is enabled — the operator consumes the
`knative.dev` and `operator.knative.dev` CRDs at runtime.

Vendored from two upstream releases (combined here because the previous
`charts/knative-operator-crds` chart, now deprecated, hand-merged them):

| Source | Provides |
|---|---|
| `knative/serving` release `knative-<VERSION>/serving-crds.yaml` | 12 CRDs (`*.serving.knative.dev`, `*.networking.internal.knative.dev`, `*.autoscaling.internal.knative.dev`, `*.caching.internal.knative.dev`) |
| `knative/operator` release `knative-<VERSION>/operator.yaml`, filtered to `kind: CustomResourceDefinition` | 2 CRDs (`knativeservings.operator.knative.dev`, `knativeeventings.operator.knative.dev`) |

The version is pinned in [`VERSION`](VERSION).

## Refresh

```bash
# From repo root
vim crds/knative-operator/VERSION   # bump e.g. v1.16.0 → v1.17.0
make vendor-crds                    # re-pulls from upstream, splits per CRD, injects SSA annotation
make check-vendored-crds            # drift gate (also runs in CI)
git diff                            # review, then commit
```

[`scripts/sync.sh`](scripts/sync.sh) is the only thing that should ever write
to `crd-*.yaml` — hand edits are overwritten on the next sync. To patch a
CRD downstream, use kustomize on the ArgoCD source or a helm post-render.
