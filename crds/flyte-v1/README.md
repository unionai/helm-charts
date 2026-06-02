# Flyte v1 CRDs (mirror)

Union-maintained CRDs for Flyte v1 (currently just `flyteworkflows.flyte.lyft.com`).

**This directory is a mirror, not the source of truth.** The canonical file
lives in the dataplane chart's Helm-managed `crds/` directory at:

  [`charts/dataplane/crds/crd-flyteworkflows.yaml`](../../charts/dataplane/crds/crd-flyteworkflows.yaml)

That chart-dir copy is installed automatically by `helm install` (Helm 3
`crds/` convention). The mirror here exists so a dedicated ArgoCD
`Application` (or `kubectl apply --server-side -f crds/flyte-v1/`) can
install the same CRD with SSA when the customer opts out of Helm-managed
CRDs (`helm install --skip-crds`). Both paths apply byte-identical YAML.

## Editing

Edit the chart-dir file. Then run:

```bash
make vendor-crds        # regenerates crd-*.yaml in this directory
make check-vendored-crds # CI also runs this; fails on drift
```

`scripts/sync.sh` simply copies from the chart dir into this directory with
an AUTO-GENERATED header injected; `scripts/check.sh` re-runs sync.sh into a
tmp dir and diffs.

See [`../README.md`](../README.md) for the broader vendoring rationale and
the equivalent layout used for upstream-tracked subchart CRDs.
