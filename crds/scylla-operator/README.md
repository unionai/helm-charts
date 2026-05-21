# scylla-operator CRDs

Vendored from `scylla/scylla-operator`. Version pinned in [`VERSION`](VERSION);
kept in sync with the `scylla-operator` dep in
[`charts/controlplane/Chart.yaml`](../../charts/controlplane/Chart.yaml) by
[`scripts/sync.sh`](scripts/sync.sh) and gated by
[`scripts/check.sh`](scripts/check.sh).

Used only by `controlplane` (scylla is not a `dataplane` dep).

See [`../README.md`](../README.md) for the rationale. Note that
scylla-operator ships CRDs in the chart's `crds/` directory (Helm 3
convention), which means Helm itself does not manage their lifecycle on
upgrade — the historical workaround was the `install-scylla-crds.sh` script
in `charts/controlplane/scripts/`. Vendoring + dedicated ArgoCD Application
supersedes that script.

## Refresh

```bash
# from repo root
make vendor-crds
```

This is also run automatically by `make generate-expected`.
