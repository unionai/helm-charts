# Knative Operator CRDs (operator-type only)

The 2 `operator.knative.dev` CRDs (`knativeservings`, `knativeeventings`)
that the `knative-operator` subchart consumes. Vendored from upstream
`knative/operator` at the version pinned in [`VERSION`](VERSION).

Knative *serving* CRDs (12 in `serving.knative.dev`,
`networking.internal.knative.dev`, `autoscaling.internal.knative.dev`,
`caching.internal.knative.dev`) are **NOT** here — they live in
[`crds/dataplane/`](../dataplane/) because the dataplane chart needs them
in both zero-trust mode (operator subchart disabled) and legacy mode
(operator subchart enabled), so the parent chart owns them.

## When to delete this directory

When the `knative-operator` subchart is eventually retired — zero-trust
mode (`zero_trust.enabled: true` + `knative-operator.enabled: false`)
becomes the only supported mode — these 2 CRDs lose their only consumer.
Delete:

- `crds/knative-operator/` (this dir)
- `charts/knative-operator/crds/`
- The whole `charts/knative-operator/` subchart
- The `crds/knative-operator` source from the cloud-side ArgoCD appsets
  (`appset-selfmanaged-dataplane-crds.yaml`,
  `appset-selfmanaged-data-plane-crds-legacy.yaml`)

The serving CRDs in `crds/dataplane/` stay — the zero-trust gateway needs
them.

## Two on-disk copies

[`scripts/sync.sh`](scripts/sync.sh) writes the same 2 `crd-*.yaml` files
to two byte-identical locations:

| Location | Purpose |
|---|---|
| `crds/knative-operator/` (this dir) | SSA-install mirror for the `helm install --skip-crds` path and the dedicated ArgoCD CRD-only Application. Users `kubectl apply --server-side` from here. |
| `charts/knative-operator/crds/` | Consumed by Helm's chart-`crds/` convention so the subchart auto-installs the CRDs on a default `helm install` (no `--skip-crds` flag needed). |

`make check-vendored-crds` enforces parity between the two copies — hand
editing either one will fail the drift gate.

## Refresh

```bash
# From repo root
vim crds/knative-operator/VERSION   # bump e.g. v1.16.0 → v1.17.0
make vendor-crds                    # re-pulls from upstream, filters to operator.knative.dev, writes both locations
make check-vendored-crds            # drift gate (also runs in CI)
git diff                            # review, then commit
```

[`scripts/sync.sh`](scripts/sync.sh) is the only thing that should ever write
to `crd-*.yaml` — hand edits are overwritten on the next sync. To patch a
CRD downstream, use kustomize on the ArgoCD source or a helm post-render.
