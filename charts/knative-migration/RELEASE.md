# knative-migration — Release Notes

`appVersion` tracks the migration tool's own `0.1.0`, not the control-plane / data-plane image tag.

## 2026.8.4

Lockstep `version` bump with the `controlplane` / `dataplane` charts
(`2026.8.3` → `2026.8.4`); `appVersion` stays at the migration tool's own
`0.1.0`. No migration-tool or template changes.

## 2026.8.3

Lockstep `version` bump with the `dataplane` chart (`2026.8.2` → `2026.8.3`).
No functional changes in this release.

## 2026.8.2

Lockstep `version` bump with the `dataplane` chart (`2026.8.1` → `2026.8.2`).
No functional changes in this release.

## 2026.8.1

Lockstep `version` bump with the `controlplane` / `dataplane` charts (`2026.8.0` -> `2026.8.1`).
No migration-tool or template changes.

## 2026.8.0

Lockstep `version` bump with the `controlplane` / `dataplane` charts (`2026.7.2` →
`2026.8.0`); `appVersion` stays at the migration tool's own `0.1.0`. One values change.

### Configuration changes

- **Fully qualified image repository path** ([#509](https://github.com/unionai/helm-charts/pull/509), FAB-438). `image.repository` is now
  `docker.io/alpine/kubectl` (was `alpine/kubectl`). An unqualified repository
  resolves against the implicit `docker.io/` default, which clusters running an
  allowed-registry admission policy reject with `ErrImagePull`. Same image, same
  tag — only the name is now explicit.

## 2026.7.2

Lockstep `version` bump only. No migration-tool or template changes.

## 2026.7.1

Chart-only patch release (lockstep bump).

## 2026.7.0

`version` bumped to `2026.7.0`; `appVersion` stayed `0.1.0` (tracks the tool version).

## 2026.6.9

### Changes

- Zero trust metrics push (#447) (5e59a4d)

## 2026.6.7

### Changes

- Release/2026.6.7 (#451) (d472cd8)

## 2026.6.6

> **Release-train alignment only.** The chart's `version` jumps `2026.5.0 → 2026.6.6` to align with the rest of the helm-charts release train; `appVersion` stays at `0.1.0` because the migration logic itself is unchanged.

### Highlights

- **Chart `version` bumped to `2026.6.6`** to align with the controlplane / dataplane release train.
- **`appVersion` unchanged (`0.1.0`)** — the cleanup Job logic, RBAC scope, and install-mode contract (Helm hook / Argo hook / plain resources via annotations) are byte-identical to `knative-migration-2026.5.0`.

### Helm chart changes (since `knative-migration-2026.5.0`)

- Chart `version` bumped `2026.5.0 → 2026.6.6`; `appVersion` unchanged.
- `Chart.yaml` `description` field cosmetically re-folded (single string with embedded blank lines instead of the prior block-scalar form). No semantic change.
- No template, RBAC, or values changes.

### Image changes (appVersion `0.1.0` → `0.1.0`)

- None — `appVersion` did not advance.

### Migration notes

No migrations required. This chart's purpose is one-shot cleanup of `knative-operator` residue (stuck `KnativeServing` finalizer, operator CRDs, operator ClusterRoles/Bindings) left behind after migrating the Union dataplane chart away from `KnativeServing` CR-based installation. Continue to invoke it the same way you did with `2026.5.0` — install-mode (Helm hook vs Argo hook vs plain resources) is still chosen by the caller via annotations.

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
