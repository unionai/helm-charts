# dataplane-crds — Release Notes

## 2026.8.2

Lockstep `version` bump with the `dataplane` chart (`2026.8.1` → `2026.8.2`).
No CRD changes in this release.

## 2026.8.1

Lockstep `version` bump with the `dataplane` chart (`2026.8.0` -> `2026.8.1`).
No CRD changes in this release.

## 2026.8.0

Lockstep `version` bump with the `dataplane` chart (`2026.7.2` → `2026.8.0`);
`appVersion` stays `2026.7.2`. **No CRD changes in this release** — the minor bump
tracks the data-plane chart's breaking changes, not a CRD schema change, so there is
no CRD apply ordering concern beyond the usual install-before-upgrade.

## 2026.7.2

Lockstep version bump with the `dataplane` chart. `appVersion` realigned to `2026.7.2`. No CRD changes in this release.

## 2026.7.1

Chart-only patch release (lockstep bump); `appVersion` stayed `2026.7.0`.

## 2026.7.0

First stable `2026.7.0`. `version` + `appVersion` bumped to `2026.7.0`.

## 2026.6.9

### Changes

- Zero trust metrics push (#447) (5e59a4d)

## 2026.6.7

### Changes

- Release/2026.6.7 (#451) (d472cd8)

## 2026.6.6

> **Deprecated chart.** Catch-up release that aligns `dataplane-crds` with the rest of the release train (`version` jumps `2026.6.1 → 2026.6.6`; previously frozen while the migration to vendored CRDs landed). No template changes; the deprecation guidance below is unchanged.

### Highlights

- **`version` + `appVersion` bumped to `2026.6.6`** to align with the controlplane / dataplane release train. No template, values, or dependency changes.
- **`README.md` deprecation pointer refreshed** — the vendored-CRD replacement is now consolidated at `crds/dataplane/` (covers both `flyteworkflows.flyte.lyft.com` and the Knative Serving CRDs). Previous text pointed only at `crds/flyte-v1/`.
- **This chart remains deprecated.** New deployments should consume vendored CRDs directly:
    - `crds/dataplane/` — FlyteWorkflow + Knative Serving CRDs
    - `crds/kube-prometheus-stack/` — prometheus-operator CRDs

### Helm chart changes (since `dataplane-crds-2026.6.1`)

- Chart `version` bumped `2026.6.1 → 2026.6.6`; `appVersion` bumped `2026.6.0 → 2026.6.6` to align with the rest of the train.
- `README.md` updated to point at the consolidated vendored-CRD path (`crds/dataplane/`).
- No template changes.

### Image changes (appVersion `2026.6.0` → `2026.6.6`)

- This chart only renders CRDs; no images.

### Migration notes

- **Migrate off this chart.** Replace with `kubectl apply --server-side -f crds/dataplane/` (or point ArgoCD at the same path) plus `crds/kube-prometheus-stack/`. The bundled CRD content is byte-identical to what this chart previously rendered.

## 2026.6.1

### Changes

- Release 2026.6.1 (#419) (23d2631)

## 2026.6.0

### Changes

- Changes to enable billing collection in low priv mode (#411) (65093fa)

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
