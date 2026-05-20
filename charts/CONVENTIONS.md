# Chart Conventions

## Overlay file naming

Each chart in `charts/` ships overlay files alongside the base `values.yaml`:

- **`values.yaml`** — base defaults for every deployment
- **`values.{cloud}.yaml`** — per-cloud canonical overlay (`aws`, `gcp`, `azure`)
- **`values.{cloud}.{mode}.yaml`** — mode-specific overlay layered on top of the per-cloud overlay (e.g. `values.aws.eks-automode.yaml`)
- **`values.{purpose}.yaml`** — orthogonal opt-in overlays not tied to a cloud (e.g. `values.registry.yaml`, `values-legacy.yaml`, `values-test-certs.yaml`, `values.v2_and_v1.yaml`)
- **`examples/`** — example values files we do **not** test; starting points for non-default deployments

## We only ship overlays for configurations we actively test

If a values file lives at one of the canonical paths above (not under `examples/`), the chart's snapshot tests (`tests/`) exercise it. Conversely: if a configuration is not test-covered, we don't ship a top-level overlay for it.

Why this matters:
- Shipping untested overlays as defaults creates a maintenance footgun — they drift from chart template changes and start producing invalid manifests, often silently
- An "example" labelled clearly tells the operator they're starting from something we don't promise to keep working over time
- Reduces the surface area new contributors have to mentally maintain

If you want a new configuration to become a first-class overlay:
1. Add a snapshot test under `tests/values/` that exercises it
2. Promote the file to a canonical path
3. Document any cross-cutting concerns in `MIGRATION.md` if existing consumers are affected

See [MIGRATION.md](./MIGRATION.md) for the migration story behind the current state.
