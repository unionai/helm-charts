# controlplane — Release Notes

## 2026.7.2

Bumps `version` + `appVersion` to `2026.7.2`. `appVersion` moves from `2026.7.0` to
`2026.7.2`, so this release points at new control-plane images (notes below are the diff
against the last stable release, `2026.7.1`, whose `appVersion` was still `2026.7.0`).

### Configuration changes (helm-charts)

- **Image-builder bootstrap Job is now opt-in** ([#492](https://github.com/unionai/helm-charts/pull/492)). `imageBuilder.bootstrap.enabled` defaults to `false`. The bootstrap Job registers the build-image task into `system`/`production` and only succeeds when that project routes (queue → cluster-pool → cluster) to a functional cluster whose write role holds the fast-registration bucket's KMS/S3 permissions; running it unconditionally made installs/upgrades fail as a post-install hook where those prerequisites weren't in place. **Action:** deployments relying on automatic build-image registration must set `imageBuilder.bootstrap.enabled: true` once routing + bucket permissions are configured (see Migration).
- **`services.identity.apiKeyOverrides` is now a list, not a map** ([#491](https://github.com/unionai/helm-charts/pull/491)) — **breaking values-shape change** (documented in [`charts/MIGRATION.md`](../MIGRATION.md)). Each entry is `{key, clusterName?, existingSecret}`, letting a control plane seed a distinct OAuth client per data plane for the same system key (e.g. a per-cluster `EAGER_API_KEY`). An entry without `clusterName` is the nameless default; a cluster-scoped entry wins for that data plane. Mount paths are per-entry (`/etc/secrets/apikey/<KEY>` or `<KEY>-<clusterName>`).
- **Documented the `dataplaneClusters` bootstrap object form** ([#489](https://github.com/unionai/helm-charts/pull/489)) — `{name, operators, viewers}` in `values.yaml` comments. Comment-only; the `dataplaneClusters: []` default and rendered output are unchanged.

### Platform (control-plane images — `appVersion 2026.7.2`)

The `appVersion` bump carries the control-plane images the chart changes above depend on:

- **Per-data-plane OAuth clients.** The identity service honors per-cluster `apiKeyOverrides` entries (with a nameless-default fallback), which is what makes the new list-shaped `apiKeyOverrides` ([#491](https://github.com/unionai/helm-charts/pull/491)) take effect.
- **`dataplaneClusters` object form.** The authorizer bootstrap accepts the `{name, operators, viewers}` object the chart now documents ([#489](https://github.com/unionai/helm-charts/pull/489)).

Otherwise the `2026.7.2` tag is a routine control-plane image roll (bug fixes and improvements); nothing else in this chart release depends on it.

### Migration / action required

- **`apiKeyOverrides` map → list** ([#491](https://github.com/unionai/helm-charts/pull/491)). Env overlays still carrying the map shape must regenerate in lockstep with bumping to this chart version. See [`charts/MIGRATION.md`](../MIGRATION.md).
- **Image-builder bootstrap default flip** ([#492](https://github.com/unionai/helm-charts/pull/492)). If you relied on automatic build-image registration, set `imageBuilder.bootstrap.enabled: true` and ensure `system`/`production` routes to a cluster with the required bucket permissions; otherwise no action.

## 2026.7.1

Chart-only patch release on top of `2026.7.0`; `appVersion` stayed `2026.7.0`. Highlights: zero-trust mode GA for self-managed/BYOC data planes; `actionsLeasor.enabled` defaults to `true`; consolidated control-plane host resolution and Gateway/ingress template updates. See [PR #483](https://github.com/unionai/helm-charts/pull/483).

## 2026.7.0

First stable `2026.7.0`; `version` + `appVersion` bumped to `2026.7.0`. Highlights: dataplane self-registration + multi-dataplane routing via the new `direct` dataproxy cluster selector (opt-in; default stays `local`); removal of the `global.DATAPLANE_HOST` / `global.DATAPLANE_ENDPOINT` required globals. See [PR #472](https://github.com/unionai/helm-charts/pull/472).
