# kube-prometheus-stack CRDs

Vendored from `prometheus-community/kube-prometheus-stack`. Version pinned in
[`VERSION`](VERSION); kept in sync with the `kube-prometheus-stack` dep in
[`charts/controlplane/Chart.yaml`](../../charts/controlplane/Chart.yaml) by
[`scripts/sync.sh`](scripts/sync.sh) and gated by
[`scripts/check.sh`](scripts/check.sh).

See [`../README.md`](../README.md) for the rationale.

## Refresh

```bash
# from repo root
make vendor-crds
```

This is also run automatically by `make generate-expected`.
