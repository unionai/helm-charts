# Chart Conventions

## Release notes (`RELEASE.md`)

Every published chart carries a `charts/<chart>/RELEASE.md` — human-authored release
notes with one **newest-first** section per version, headed `## <version>`:

```markdown
# <chart> — Release Notes

## 2026.7.2
<what changed in this version>

## 2026.7.1
...
```

Rules:
- **A `version:` bump in `Chart.yaml` must add a matching `## <version>` section** to the
  same chart's `RELEASE.md`, in the same PR. CI enforces this
  (`.github/ci-scripts/check_release_notes.sh`, run by the `release-notes` job).
- Write the section for a chart consumer: config/default/template changes for that chart,
  and — when `appVersion` moves — a short summary of the control-plane / data-plane image
  behavior the new tag brings.
- Keep entries terse and factual; link PRs as `(#NNNNN)`. A pure lockstep bump with no
  functional change is a valid one-line entry.

This per-chart, section-per-version layout is what lets an on-merge step read just the
newly-added section to assemble aggregate release notes.

## Overlay file naming

Each chart in `charts/` follows this exact layout:

- **`values.yaml`** — base defaults for every deployment
- **`values.{cloud}.yaml`** — per-cloud canonical overlay (`aws`, `gcp`, `azure`, future: `oci`, `openshift`). Describes the **general case** for that cloud — a split CP/DP topology, with no intra-cluster assumptions baked in. The single canonical overlay per cloud is the surface area we guarantee.
- **`examples/`** — every other overlay lives here. Intra-cluster topology, custom registries, EKS Automode, v1/v2 dual-mode, test fixtures, BYOC migration patterns. Operators layer these on top of a `values.{cloud}.yaml` as needed.

Anything not in the bulleted list above is excess and should be moved or removed.

## We only ship canonical overlays for configurations we actively test

If a values file lives at one of the canonical paths above (not under `examples/`), the chart's snapshot tests (`tests/`) exercise it. Conversely: if a configuration is not test-covered, it lives in `examples/`.

Why this matters:
- Shipping untested overlays as defaults creates a maintenance footgun — they drift from chart template changes and start producing invalid manifests, often silently
- An "example" labelled clearly tells the operator they're starting from something we don't promise to keep working over time
- Reduces the surface area new contributors have to mentally maintain

If you want a new configuration to become a first-class overlay:
1. Add a snapshot test under `tests/values/` that exercises it
2. Promote the file to a canonical path
3. Document any cross-cutting concerns in `MIGRATION.md` if existing consumers are affected

See [MIGRATION.md](./MIGRATION.md) for the migration story behind the current state.
