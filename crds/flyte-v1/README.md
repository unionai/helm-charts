# Flyte v1 CRDs

Union-maintained CRDs for Flyte v1 (currently just `flyteworkflows.flyte.lyft.com`).
Edit `crd-*.yaml` directly — there is no upstream chart to sync from, so this
directory ships no `scripts/sync.sh` (unlike the other `crds/<name>/` dirs).

Replaces the `flyteworkflow` template that lived in
[`charts/dataplane-crds`](../../charts/dataplane-crds/) (now deprecated).

See [`../README.md`](../README.md) for the broader vendoring rationale.
