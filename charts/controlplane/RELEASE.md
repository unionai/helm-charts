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

High-level summary of the behavior in the images this chart now points at:

- **Runs & executions.** `CreateRun` fails fast with `InvalidArgument` on pod-plugin task specs with an empty container image (previously admitted, then burned ~30 retries in "Queued" before failing). Run-store hydration, group filtering, and nested-action aggregation under groups fixed. Redis `BUSYGROUP` responses no longer misclassified as errors. Groundwork for run recovery: a new terminal, success-equivalent `RECOVERED` action phase is understood across the actions/workflow/queue/leasor path (nothing emits it yet).
- **Queues & clusters.** Queue lifecycle management — drain, re-`Activate` a draining/drained queue, and settings validation before draining; `ListQueues` has a stable default order. `DeleteCluster` is blocked while explicit queues still point at the cluster. New cluster-health/management surface (`UpdateCluster`, `WatchClusters`, cluster-status write path, `WatchQueueMetrics`) with corrected authz on the read-only Cluster API.
- **Apps.** Org-scoped `app.disallow_anonymous` is enforced on app create/update (fails closed if the settings lookup errors) and re-asserted by the operator on resync. App terminal-FAILED classification now keys off deployment identity rather than the revision counter. Scaled-to-zero apps fall back to persisted logs instead of showing empty.
- **Authorization.** Authorizer syncs desired edge attributes at startup and tolerates stale edge types, so edge-type updates take effect. Roles gain an editable description. The leasor's internal queue-manager service is now behind the authz middleware.
- **Settings & notifications.** Fixed `run_base_dir` being dropped from settings; added settings mutation/apply logging; dataproxy adopts the shared settings cache. Paused-action notifications use a dedicated template.
- **Billing/usage.** Cluster-less child actions are now reported; invalid cluster lookups during billable-usage reporting fixed; terminal-action billing index updated; monthly contracts respect their start time.
- **Console (UI).** Run lineage (rerun/recover/clone) surfaced as a badge on run details and run-list rows; large-fanout expand/collapse and sidebar stability fixes. New cluster details page; live queue metrics in the queues UI; role-modification UI. Launch-form refactor with a nested-input handling fix and dynamic execution-settings domains.

### Migration / action required

- **`apiKeyOverrides` map → list** ([#491](https://github.com/unionai/helm-charts/pull/491)). Env overlays still carrying the map shape must regenerate (Terraform re-apply for self-managed) in lockstep with bumping to this chart version. See [`charts/MIGRATION.md`](../MIGRATION.md).
- **Image-builder bootstrap default flip** ([#492](https://github.com/unionai/helm-charts/pull/492)). If you relied on automatic build-image registration, set `imageBuilder.bootstrap.enabled: true` and ensure `system`/`production` routes to a cluster with the required bucket permissions; otherwise no action.
- **Optional SDK ≥ 2.0.4 gate.** The platform can reject `CreateRun` from SDKs older than `2.0.4` (`FailedPrecondition`). This is **off by default**; enable only after confirming no orgs are still on sub-`2.0.4` SDKs.
- **DB migrations** are additive/reversible and require no operator action.

## 2026.7.1

Chart-only patch release on top of `2026.7.0`; `appVersion` stayed `2026.7.0`. Highlights: zero-trust mode GA for self-managed/BYOC data planes; `actionsLeasor.enabled` defaults to `true`; consolidated control-plane host resolution and Gateway/ingress template updates. See [PR #483](https://github.com/unionai/helm-charts/pull/483).

## 2026.7.0

First stable `2026.7.0`; `version` + `appVersion` bumped to `2026.7.0`. Highlights: dataplane self-registration + multi-dataplane routing via the new `direct` dataproxy cluster selector (opt-in; default stays `local`); removal of the `global.DATAPLANE_HOST` / `global.DATAPLANE_ENDPOINT` required globals. See [PR #472](https://github.com/unionai/helm-charts/pull/472).
