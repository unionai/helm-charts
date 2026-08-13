# sandbox — Release Notes

## 2026.8.1

Lockstep `version` bump (`2026.8.0` -> `2026.8.1`). No sandbox chart changes in this release.

## 2026.8.0

Lockstep `version` bump (`2026.7.2` → `2026.8.0`); `appVersion` stays `2026.7.2`, so the
control-plane / data-plane images are unchanged. No sandbox chart changes in this release.

## 2026.7.2

Lockstep version bump. `appVersion` realigned to `2026.7.2` (control-plane / data-plane images). No sandbox chart changes in this release.

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

> Chart-only release: no `charts/sandbox/` files changed in this release window.

### Highlights

- **Version + `appVersion` bumped to `2026.6.6`** to stay aligned with the controlplane / dataplane release train.
- **Releases `2026.6.4` and `2026.6.5` were skipped** in the publish sequence — going straight from `2026.6.3` to `2026.6.6` is intentional.

### Helm chart changes (since `sandbox-2026.6.3`)

- Chart `version` + `appVersion` bumped to `2026.6.6`. No template, values, or helper changes.

### Image changes (appVersion `2026.6.3` → `2026.6.6`)

- No sandbox-specific image deltas. The bumped `appVersion` is purely for release-train alignment.

### Migration notes

No migrations required.

## 2026.6.3

> Chart-only release: no `charts/sandbox/` files changed in this release window.

### Highlights

- **Version + `appVersion` bumped to `2026.6.3`** to stay aligned with the controlplane / dataplane release train.

### Helm chart changes (since `sandbox-2026.6.2`)

- Chart `version` + `appVersion` bumped to `2026.6.3`. No template, values, or helper changes.

### Image changes (appVersion `2026.6.2` → `2026.6.3`)

- No sandbox-specific image deltas. The bumped `appVersion` is purely for release-train alignment.

### Migration notes

No migrations required.

## 2026.6.2

### Changes

- Release 2026.6.2 (#434) (a06117d)

## 2026.6.1

### Changes

- Release 2026.6.1 (#419) (23d2631)

## 2026.6.0

### Changes

- Changes to enable billing collection in low priv mode (#411) (65093fa)

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
