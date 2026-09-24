# controlplane — Release Notes

## 2026.9.5

`version` and `appVersion` move `2026.9.4` → `2026.9.5`. Controlplane templates
and values are unchanged.

### Control-plane and console images

- Artifacts: typed partitions on artifact versions, with a monthly-partitioned
  table behind them ([cloud#18522](https://github.com/unionai/cloud/pull/18522)).
- Executions: run notifications no longer ride on Postgres `NOTIFY`; the
  inline payload is capped and sized with `>=` ([cloud#18547](https://github.com/unionai/cloud/pull/18547),
  [cloud#18544](https://github.com/unionai/cloud/pull/18544), [cloud#18546](https://github.com/unionai/cloud/pull/18546)).
- `Inputs.context` is excluded from the root action cache key ([cloud#18567](https://github.com/unionai/cloud/pull/18567)).
- Identity: cache prefetchers start staggered to avoid synchronized provider
  enumerations ([cloud#18553](https://github.com/unionai/cloud/pull/18553)).
- Console: runs can be searched by run ID as well as task name ([cloud#18395](https://github.com/unionai/cloud/pull/18395)).

Image source: [cloud changes since release/2026.9.4](https://github.com/unionai/cloud/compare/release/2026.9.4...release/2026.9.5).

## 2026.9.4

`version` and `appVersion` move `2026.9.3` → `2026.9.4`. Controlplane templates
and values are unchanged.

### Control-plane and console images

- Runs search matches run name as well as task name. The server accepts a
  synthetic `search` run filter (`run_name` OR `task_name`), so searching a run
  ID on the Runs page now finds it ([cloud#18391](https://github.com/unionai/cloud/pull/18391)).
- Tasks record their type at registration and `ListTasks` can filter on
  `task_type`. This adds a `tasks.task_type` column and partial index via a
  schema migration; tasks registered before the upgrade read as an empty type
  until re-registered ([cloud#18510](https://github.com/unionai/cloud/pull/18510)).
- `RunSpec` carries the org's task resource settings (requests and max),
  resolved from Settings at `CreateRun` time, including re-runs and recovers.
  When no scope sets task resource settings, behavior is unchanged
  ([cloud#18479](https://github.com/unionai/cloud/pull/18479)).
- Apps can be served on multiple dataplanes. A new `app_dns_strategy` setting
  (`shared` by default, preserving today's single tenant-wide app URL) or
  `dataplane_specific` for per-cluster app URLs, plus cluster pinning for app
  placement ([cloud#17548](https://github.com/unionai/cloud/pull/17548)).
- Flyteadmin proxies the OAuth device authorization endpoint (`/auth/device`)
  the same way it proxies `/auth/token`, so device-flow logins work with
  non-default identity providers ([cloud#18436](https://github.com/unionai/cloud/pull/18436),
  [flyte#1013](https://github.com/unionai/flyte/pull/1013)).
- `DeleteCluster` / `UndeleteCluster` authorize against the org, so a cluster
  record whose authz resource was already removed during teardown can still be
  deleted; undelete restores the resource ([cloud#18491](https://github.com/unionai/cloud/pull/18491)).
- Console: Metrics tab readability fixes for multi-pod, multi-GPU actions;
  created-by / updated-by avatars on queues and clusters; Run details sidebar
  refactor ([cloud#18415](https://github.com/unionai/cloud/pull/18415), [cloud#18494](https://github.com/unionai/cloud/pull/18494),
  [cloud#18450](https://github.com/unionai/cloud/pull/18450)).

Image source: [cloud changes since release/2026.9.3](https://github.com/unionai/cloud/compare/release/2026.9.3...release/2026.9.4).
Included submodule changes: [Flyte v1](https://github.com/unionai/flyte/compare/4011364765dfea33d6431db11afdffef01ab1609...8b7a3dd295114f10cbce4b7d4e7c8b06ca171d29)
and [Flyte v2](https://github.com/flyteorg/flyte/compare/a2aec3f7210f450b35b34b9e924f3cef9f60ee2f...96825115189e6b51e9be48988adab79bdaef5974).

## 2026.9.3

`version` moves `2026.9.1` → `2026.9.3` and `appVersion` moves `2026.9.1` →
`2026.9.3`. Chart version `2026.9.2` was not published; image version `2026.9.2`
was published separately. Controlplane templates and values are unchanged.

### Control-plane and console images

- Settings > Clusters > Logs requests namespace `auto`, which the new operator
  proxy resolves to its own namespace. The control plane forwards explicit
  namespaces unchanged. Upgrade all connected dataplane proxies before deploying
  these control-plane/console images; reverse that order for rollback
  ([cloud#18400](https://github.com/unionai/cloud/pull/18400)).
- Zero-trust metrics queries no longer require the control-plane tunnel
  ([cloud#18296](https://github.com/unionai/cloud/pull/18296)). Untouched datetime
  inputs retain fractional seconds through launch-form hydration, including
  Recover and Rerun; directly editing the datetime widget can still reduce
  precision ([cloud#18347](https://github.com/unionai/cloud/pull/18347)).
- Artifact versions can be deleted, sorted, and filtered by creator or metadata;
  artifact cards support fullscreen viewing. Deleting a version does not delete
  its offloaded blob data
  ([cloud#18307](https://github.com/unionai/cloud/pull/18307),
  [cloud#18336](https://github.com/unionai/cloud/pull/18336)).
- Queue resource caps are enforced when the leasor uses the `v2` scheduling
  strategy. Strict FIFO and greedy-capacity policies control handling of work
  that cannot currently fit; requests exceeding the whole cap fail as
  unschedulable. Console controls and utilization/head-block displays require
  the `queue-resource-caps` feature gate, which defaults off for selfhosted
  installations. Existing caps survive unrelated console edits regardless of
  that gate ([cloud#18295](https://github.com/unionai/cloud/pull/18295),
  [cloud#18350](https://github.com/unionai/cloud/pull/18350)).
- GPU faults appear with structured explanations in run errors and as markers on
  GPU metric charts when fault data is available
  ([cloud#17807](https://github.com/unionai/cloud/pull/17807)).
- Cluster pages expose drain/deletion state and actions. Registration checks
  names through organization-scoped listings and rejects duplicate Fleet names;
  organizations can hold multiple Fleet deployment targets. Cluster-pool
  heartbeats fill undefined configuration fields without replacing defined
  values ([cloud#18193](https://github.com/unionai/cloud/pull/18193),
  [cloud#18294](https://github.com/unionai/cloud/pull/18294),
  [cloud#18285](https://github.com/unionai/cloud/pull/18285),
  [cloud#18287](https://github.com/unionai/cloud/pull/18287),
  [cloud#18393](https://github.com/unionai/cloud/pull/18393)).
- Clusters, pools, and queues report creator/updater identity. Fleet applies
  stored configuration revisions with persisted checkpoints and error details;
  chart upgrades remain separate from that apply operation
  ([cloud#18321](https://github.com/unionai/cloud/pull/18321),
  [cloud#18297](https://github.com/unionai/cloud/pull/18297)).
- Missing projects return NotFound to callers with organization-level project
  visibility; the console shows a stable not-found page for invalid project or
  domain URLs ([cloud#18394](https://github.com/unionai/cloud/pull/18394),
  [cloud#18402](https://github.com/unionai/cloud/pull/18402),
  [cloud#18405](https://github.com/unionai/cloud/pull/18405)).
- ZITADEL username/password login now requires organization metadata
  `union.login.capabilities.v1` with `password: true`; absent, invalid, or
  unavailable metadata disables that login method
  ([cloud#18338](https://github.com/unionai/cloud/pull/18338)). The self-serve
  first-run tour is available behind the default-off `self-serve-tutorial` gate
  ([cloud#18438](https://github.com/unionai/cloud/pull/18438)).
- Image-build tasks accept pod annotations and a service account, complementing
  the chart configuration introduced in 2026.9.1
  ([cloud#18384](https://github.com/unionai/cloud/pull/18384)). Usage reporting
  supports additional AWS accelerators/TPUs and configured self-serve Omnistrate
  metering with coordinated submissions
  ([cloud#18383](https://github.com/unionai/cloud/pull/18383),
  [cloud#18088](https://github.com/unionai/cloud/pull/18088),
  [cloud#18322](https://github.com/unionai/cloud/pull/18322)).

### Upgrade and rollback considerations

The images include cluster database migrations for per-cluster deployment-target
keys, render diagnostics, authorship, and stored-apply state
([cloud#18287](https://github.com/unionai/cloud/pull/18287),
[cloud#18348](https://github.com/unionai/cloud/pull/18348),
[cloud#18321](https://github.com/unionai/cloud/pull/18321),
[cloud#18297](https://github.com/unionai/cloud/pull/18297)). The per-cluster key
cannot be rolled back while an organization has multiple deployment targets.
Treat a database downgrade as a separate compatibility review, not as part of a
chart/image rollback.

Flyte admin's execution-status watch avoids repeated closure reads and adds a
concurrent index migration; a large executions table can extend the first
upgrade while the index builds
([cloud#18373](https://github.com/unionai/cloud/pull/18373),
[cloud#18444](https://github.com/unionai/cloud/pull/18444)).

The dataplane chart's billing/tunnel changes are described in its 2026.9.3 notes
(#590). Image source: [cloud changes since release/2026.9.1](https://github.com/unionai/cloud/compare/release/2026.9.1...a60aefc8a9d2d4051576f71c818b239cf221bf4b).
Included submodule changes: [Flyte v1](https://github.com/unionai/flyte/compare/771e792c89aa11b30cbd2dab74c77e170efcecb6...4011364765dfea33d6431db11afdffef01ab1609)
and [Flyte v2](https://github.com/flyteorg/flyte/compare/6390805ff6495b87b2d172c35ccd5e6fab5567a5...a2aec3f7210f450b35b34b9e924f3cef9f60ee2f).

## 2026.9.1

Chart-only release: `version` moves `2026.9.0` → `2026.9.1`; `appVersion` stays
`2026.9.1`, so images are unchanged.

- Build-image task pod options: new `imageBuilder.bootstrap.taskPodAnnotations`
  (default `{}`) and `imageBuilder.bootstrap.taskServiceAccountName` (default `""`,
  i.e. the namespace default SA) are applied to the pods that remote image builds run
  in — not to the bootstrap Job pod. Useful for service-mesh sidecar control or a
  dedicated build identity. Defaults leave rendered pods unchanged
  ([#586](https://github.com/unionai/helm-charts/pull/586)).
- Fix empty Apps response-time charts: the P50/P90/P95 PromQL templates rendered
  `project=~"${{.Project}}"` (stray `$`), which never matched a project. Fixed in both
  the `dataproxy` and `usage` query blocks
  ([#582](https://github.com/unionai/helm-charts/pull/582)).
- GPU health metrics: 16 new `EXECUTION_METRIC_GPU_*` query templates (temperature,
  power, clock/throttle, tensor/DRAM activity, PCIe/NVLink throughput, last Xid, ECC
  and remapped-row errors) in the `dataproxy` and `usage` blocks. They need the
  matching dcgm-exporter fields; where those are not collected the queries return no
  series ([#582](https://github.com/unionai/helm-charts/pull/582)).

## 2026.9.0

`version` moves `2026.8.5` → `2026.9.0` and `appVersion` moves `2026.8.5` →
`2026.9.1`, picking up the new control-plane images plus the chart changes below. The minor bump tracks the
data-plane chart's switch to the vendored Knative gateway (see
`charts/dataplane/RELEASE.md`); the control-plane side of that work is the
app-URL / authorization wiring below.

- Self-hosted app serving: authorize app subdomains and compose public app URLs via
  `publicURLPattern`, wired into the protected gRPC-route and ingress templates
  ([#563](https://github.com/unionai/helm-charts/pull/563)).
- App-serving config: public app URL composition + apps domain wiring and the
  protected gRPC-route / ingress TLS surface for served apps
  ([#522](https://github.com/unionai/helm-charts/pull/522)).

## 2026.8.5

Chart-only lockstep release: `version` moves `2026.8.4` → `2026.8.5`;
`appVersion` stays `2026.8.5`, so images are unchanged. No control-plane
template or values changes — this release carries data-plane chart changes
only (see `charts/dataplane/RELEASE.md`).

## 2026.8.4

`version` moves `2026.8.3` → `2026.8.4` and `appVersion` moves `2026.8.3` →
`2026.8.5`, picking up the new control-plane images plus the two chart changes
below ([#552](https://github.com/unionai/helm-charts/pull/552),
[#556](https://github.com/unionai/helm-charts/pull/556)); everything else ships
in the images.

### Chart changes

- Right-size default CPU/memory **requests** for control-plane services (`actions`
  + its router, `leasor`; `scylla` CPU only) to steady-state usage. **Limits are
  unchanged**, so burst headroom is intact — only the idle reservation shrinks,
  improving pod packing so the autoscaler consolidates onto fewer nodes. Override
  `<service>.resources.requests.{cpu,memory}` to restore
  ([#552](https://github.com/unionai/helm-charts/pull/552)).
- Add a chart-level **global scheduling** default
  (`.Values.scheduling.{affinity,nodeSelector,tolerations}`) honored by every
  control-plane pod, with per-service overrides — steer the whole plane onto a
  chosen node pool (e.g. Spot) with one value. Per-service `tolerations`/`nodeSelector`
  **inherit** from the global block (concat / merge, service wins on conflicts);
  `affinity` fully overrides. Inert by default
  ([#556](https://github.com/unionai/helm-charts/pull/556)).
- Fix the generic service Deployment template and the redis-consumer
  StatefulSet rendering `tolerations` as an error object instead of a list
  whenever any toleration was set (global or per-service) — [#556]'s
  `fromYaml` on list YAML — which made `helm upgrade` fail with
  `cannot unmarshal object into Go struct field PodSpec...tolerations`
  ([#557](https://github.com/unionai/helm-charts/pull/557)).

### Schema migrations (run automatically on upgrade)

- `artifacts`: `artifacts_v2.created_by` moves from a proto-marshaled `bytea`
  blob to a plain `varchar(255)` subject, with a partial index behind a new
  `created_by` EQUAL filter on `ListArtifacts`. **Creator attribution on
  artifacts created before the upgrade is reset to empty** — the blob only ever
  held the subject. Rolling the image back requires running the migration's
  rollback too, since the old code unmarshals the column
  ([unionai/cloud#17833](https://github.com/unionai/cloud/pull/17833)).
- `artifacts`: `llm_gateway_gateways` gains
  `allow_anonymous_access boolean NOT NULL DEFAULT true`; existing gateways keep
  their current behavior
  ([unionai/cloud#17836](https://github.com/unionai/cloud/pull/17836)).
- `executions`: a backdated `20260101000000_partition_action_events` migration
  partitions `action_events` by `created_at` **on fresh databases only**. It is
  triple-guarded — already partitioned → no-op, empty → convert, has rows →
  no-op with a `NOTICE` — so an existing database upgrading through it is left
  on the unpartitioned table
  ([unionai/cloud#17817](https://github.com/unionai/cloud/pull/17817)).

### Behavior

- Artifacts resolve `created_by` into a full `EnrichedIdentity` (name, email) at
  read time, degrading to a subject-only identity when the identity cache is
  unavailable. **This chart leaves `services.artifacts.configMap.cache.identity`
  at the global `enabled: false` default**, so the console keeps rendering the
  raw OIDC subject until it is turned on for the artifacts service
  ([unionai/cloud#17833](https://github.com/unionai/cloud/pull/17833),
  [unionai/cloud#17866](https://github.com/unionai/cloud/pull/17866)).
- LLM gateway: anonymous access on the backing app is now a user-settable
  gateway option instead of a hardcoded `true`. It still defaults to on, so
  OpenAI-compatible clients keep authenticating with the virtual key alone
  ([unionai/cloud#17836](https://github.com/unionai/cloud/pull/17836)).
- `cluster`: additive IDL for the cluster drain lifecycle (`ClusterState`,
  `UpdateClusterState`, `InternalClusterService.ReportClusterWorkloadDrained`)
  and a `GetLifecycleStatus` RPC. The drain RPC is stubbed `Unimplemented` — no
  behavior change yet ([unionai/cloud#17763](https://github.com/unionai/cloud/pull/17763),
  [unionai/cloud#17834](https://github.com/unionai/cloud/pull/17834)).

### Console (`unionconsole`)

- The launch form's Settings tab gains a **Timeout** field (overall task-attempt
  timeout, in seconds). An existing task timeout is prefilled on launch and
  rerun, and can be edited or cleared before submit
  ([unionai/cloud#16525](https://github.com/unionai/cloud/pull/16525)).
- Cluster details renders a red error banner carrying `unhealthyReasons` when an
  enabled cluster is unhealthy
  ([unionai/cloud#17831](https://github.com/unionai/cloud/pull/17831)).
- The LLM gateway deploy form and detail page expose the anonymous-access
  setting (the Throughput card becomes a Configuration card)
  ([unionai/cloud#17836](https://github.com/unionai/cloud/pull/17836)).
- Flag-gated, off by default and inert for this chart: ClickHouse-backed org
  dashboards and the new `/overview` org page
  ([unionai/cloud#17663](https://github.com/unionai/cloud/pull/17663),
  [unionai/cloud#17905](https://github.com/unionai/cloud/pull/17905)), and
  self-serve onboarding tutorial cards on `/home`
  ([unionai/cloud#17827](https://github.com/unionai/cloud/pull/17827)).

## 2026.8.3

`version` moves `2026.8.2` → `2026.8.3` and `appVersion` moves `2026.8.0` →
`2026.8.3`, picking up the new control-plane images.

- Service resource names now fall back to the service key instead of the chart
  name when no `fullnameOverride`/`nameOverride` is set, so multi-service
  releases render distinct fullnames
  ([#544](https://github.com/unionai/helm-charts/pull/544)).
- The console deployment always injects `UNION_ORG_OVERRIDE`, then appends any
  user-provided `console.env` entries after it
  ([#536](https://github.com/unionai/helm-charts/pull/536)).
- Monitoring: the control-plane overview dashboard is reworked for v2 metrics
  and a new v1 overview dashboard is added alongside it
  ([#529](https://github.com/unionai/helm-charts/pull/529)).

## 2026.8.2

Chart-only release: `version` moves `2026.8.1` → `2026.8.2` while `appVersion`
stays `2026.8.0`, so the control-plane images are unchanged.

- AWS service-account identity annotations now support a configurable prefix via
  `global.AWS_POD_IDENTITY_ANNOTATION_PREFIX`; the default remains
  `eks.amazonaws.com` ([#513](https://github.com/unionai/helm-charts/pull/513)).
- Actions shard coordination init containers now use
  `actions.coordination.securityContext`, with non-root defaults suitable for
  restricted Kubernetes distributions. Shard label values are rendered
  consistently as strings across Deployments, Services, selectors, and pod
  templates ([#515](https://github.com/unionai/helm-charts/pull/515)).

## 2026.8.1

Adding redis-consumer service to control plane ([#525](https://github.com/unionai/helm-charts/pull/525)).

## 2026.8.0

Chart-only release: `version` moves `2026.7.2` → `2026.8.0` while `appVersion` stays
`2026.7.2`, so the control-plane images are unchanged. This is a **minor** bump rather
than a patch because it removes the legacy queue service — see Migration below.

### Removed: legacy queue service

The legacy queue service and corresponding executor has been removed from the chart
([#501](https://github.com/unionai/helm-charts/pull/501)), completing the deprecation
announced 2026-06-30. The actions + leasor stack is the only execution path.

- `services.queue` deleted — the queue Deployment/Service/ConfigMap (and its
  ScyllaDB `migrate` initContainer) are no longer rendered.
- Legacy routes removed — ingress + GRPCRoute rules for
  `cloudidl.workflow.{QueueService,StateService,LeaseService}` and
  `flyteidl2.workflow.{QueueService,StateService}`. The queue **CRUD** API
  (`cloudidl.queue.*`, served by the cluster binary) and leasor's
  `InternalQueueManagerService` are a different feature and are unchanged.
- `actionsLeasor` is now a deprecated no-op — v2-actions CreateRun routing is
  injected unconditionally (`useActionsServiceForOrgs=[global.UNION_ORG]`,
  `rejectLegacySDKVersions=true`). The key is ignored and will be removed in a
  future release; drop it from overlays.
- ScyllaDB is still required — it backs the leasor + actions services
  (keyspaces `leasor` / `actions`); docs previously describing it as
  queue-service-only are updated. An existing `queue` keyspace from earlier
  releases is inert; drop it manually if you want the space back.
- Removed the dead `controlplane.dbHost` / `controlplane.dbPort` helpers
  (no consumers).

### Migration / action required

- **Breaking: SDK < 2.0.4 CreateRun is hard-rejected.** There is no legacy
  fallback in this chart. Deployments that still need the legacy queue path must
  stay on chart `2026.7.2` until clients are on SDK >= 2.0.4.
- Overlays setting `actionsLeasor.enabled` or `services.queue.*` should drop
  those keys; both are ignored (harmless, but misleading).

### Configuration changes (helm-charts)

- **`connection.rootTenantURLPattern` default now the publicly-resolvable control-plane host** ([#505](https://github.com/unionai/helm-charts/pull/505)). It defaulted to the cluster-local ingress svc FQDN (`controlPlaneLibrary.ingressFqdn`), which only resolves intracluster — but this endpoint is minted into eager api-keys and dialed by **dataplane task pods** (and CP↔CP services), so a separate-cluster data plane couldn't reach it. It now defaults to `dns:///{{ .Values.global.UNION_HOST }}`. The union shared-services config and flyteadmin's config are converged on the same `global.UNION_HOST`. **Action:** none for cloud-managed envs (the generated overlay sets the topology-aware host); a standalone chart install that relied on the svc-FQDN default and runs an intracluster data plane may set `configMap.connection.rootTenantURLPattern` (and `flyte…connection.rootTenantURLPattern`) back to `dns:///{{ include "controlPlaneLibrary.ingressFqdn" . }}` via overlay.
- **Render-time guard on `connection.rootTenantURLPattern`.** The chart now fails render if the value is not a `dns:///` gRPC target or carries a trailing `:port` (control-plane services strip the `dns:///` prefix and dial the bare host, and a port corrupts the eager-api-key codec's decoded fields). No effect on valid configs.
- **Fully qualified image repository paths** ([#509](https://github.com/unionai/helm-charts/pull/509), FAB-438). Every image the chart renders now spells out its registry host. An unqualified repository resolves against the implicit `docker.io/` default, which clusters running an allowed-registry admission policy reject with `ErrImagePull`. Changed: **`services.actions.coordination.image.repository`** → `docker.io/alpine/k8s`; **`scylla-operator.image.repository`** → `docker.io/scylladb` (new override — upstream ships the bare org, and the subchart appends `/scylla-operator`); **`scylla.scyllaImage.repository`** → `docker.io/scylladb/scylla` and **`scylla.agentImage.repository`** → `docker.io/scylladb/scylla-manager-agent` (new overrides; these land in the `ScyllaCluster` CR, so the operator rather than the kubelet does the pull). No image contents change — same digests, qualified names. A `make check-image-paths` gate (wired into `make test` and the `image-paths` CI job) now fails the build on any unqualified reference.
- **Render-time consistency guard on `rootTenantURLPattern`** ([#505](https://github.com/unionai/helm-charts/pull/505)). The endpoint lives in two independent values paths — the top-level `configMap.connection` (control-plane services + the EAGER_API_KEY the operator mints and data-plane task pods dial) and `flyte.configmap.adminServer.connection` (flyteadmin-private's admin clientset cache, which the flyte subchart owns and can't share via a helm `include`). The chart now fails render if they resolve to different values, so an overlay that overrides one but not the other can't silently leave flyteadmin dialing a different control-plane host than every other service. Both still default to `dns:///{{ .Values.global.UNION_HOST }}`; override them together.
- **Cloud overlays carry only cloud-specific config** ([#498](https://github.com/unionai/helm-charts/pull/498)). The `flyte.configmap.adminServer.auth` OIDC block (appAuth/userAuth placeholders) was duplicated identically in `values.aws.yaml` and `values.gcp.yaml` and is a strict subset of the richer block base `values.yaml` already provides. OIDC auth is IdP-specific, not cloud-specific, so it belongs in base; the overlay copies are replaced with a pointer comment. Render-neutral — zero snapshot drift, no action required. (The monitoring kube-disable block stays in the overlays: base defaults those enabled for bare-k8s, and the overlays legitimately disable them.)

## 2026.7.2

Bumps `version` + `appVersion` to `2026.7.2`. `appVersion` moves from `2026.7.0` to
`2026.7.2`, so this release points at new control-plane images (notes below are the diff
against the last stable release, `2026.7.1`, whose `appVersion` was still `2026.7.0`).

### Configuration changes (helm-charts)

- **Image-builder bootstrap Job is now opt-in** ([#492](https://github.com/unionai/helm-charts/pull/492)). `imageBuilder.bootstrap.enabled` defaults to `false`. The bootstrap Job registers the build-image task into `system`/`production` and only succeeds when that project routes (queue → cluster-pool → cluster) to a functional cluster whose write role holds the fast-registration bucket's KMS/S3 permissions; running it unconditionally made installs/upgrades fail as a post-install hook where those prerequisites weren't in place. **Action:** deployments relying on automatic build-image registration must set `imageBuilder.bootstrap.enabled: true` once routing + bucket permissions are configured (see Migration).
- **`services.identity.apiKeyOverrides` is now a list, not a map** ([#491](https://github.com/unionai/helm-charts/pull/491)) — **breaking values-shape change** (documented in [`charts/MIGRATION.md`](../MIGRATION.md)). Each entry is `{key, clusterName?, existingSecret}`, letting a control plane seed a distinct OAuth client per data plane for the same system key (e.g. a per-cluster `EAGER_API_KEY`). An entry without `clusterName` is the nameless default; a cluster-scoped entry wins for that data plane. Mount paths are per-entry (`/etc/secrets/apikey/<KEY>` or `<KEY>-<clusterName>`).
- **Documented the `dataplaneClusters` bootstrap object form** ([#489](https://github.com/unionai/helm-charts/pull/489)) — `{name, operators, viewers}` in `values.yaml` comments. Comment-only; the `dataplaneClusters: []` default and rendered output are unchanged.
- **Cacheservice storage migrated to the `stow` form** ([#494](https://github.com/unionai/helm-charts/pull/494)) — the s3 branch of the cacheservice storage config moves off the legacy connection shape, which newer control-plane images no longer accept. Rolls in either order (the image prefers the `stow` form when present). Control-plane companion to the data-plane AWS stow migration (#493).

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

## 2026.6.9

### Changes

- Zero trust metrics push (#447) (5e59a4d)
- Selfmanaged controlplane: apiKeyOverrides, dataproxy connection host, operator eager-key toggle (#455) (8bd680d)

## 2026.6.7

### Changes

- Release/2026.6.7 (#451) (d472cd8)

## 2026.6.6

> **No chart-template or values changes.** This release advances the bundled `unionoperator` image tag and otherwise carries only the standard chart label / `helm.sh/chart` bumps.

### Highlights

- **Bundled `unionoperator` image tag advances `2026.6.3 → 2026.6.6`** (chart `appVersion` follows). Server-side, the operator gains support for offloaded trigger inputs (Action triggers no longer need to materialize large inputs inline); nothing to configure on the chart side.
- **Releases `2026.6.4` and `2026.6.5` were skipped** in the publish sequence — going straight from `2026.6.3` to `2026.6.6` is intentional.

### Helm chart changes (since `controlplane-2026.6.3`)

- Chart `version` + `appVersion` bumped to `2026.6.6`. No template, helper, or values changes.
- Snapshot fixtures regenerated. The only deltas are the `helm.sh/chart: controlplane-2026.6.6` label, the `app.kubernetes.io/version` label, and the `unionoperator` image tag.

### Image changes (appVersion `2026.6.3` → `2026.6.6`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.3` → `:2026.6.6` across every appVersion-tied workload (leaseworker, executor, operator-proxy, leasor, build-image, etc.).

### Migration notes

No migrations required. Routine `helm upgrade` from `controlplane-2026.6.3` carries no values changes.

## 2026.6.3

### Highlights

- **New Actions service + Leasor service templates — render by default** (`actions.enabled: true` is the chart default; `services.leasor` is present out of the box). The Actions service is sharded by action partition (`fnv32a("org:project:domain:run:parentAction") % 1024`) and fronted by an Envoy router — the same routing semantics Union's managed controlplane runs. **Adopters should expect a real footprint delta on chart upgrade**: 10 shard Deployments, the `actions-router` (Envoy), `actions-coordination`, and `leasor` pods now appear in the controlplane namespace. Capacity-plan accordingly. To skip the infra entirely, set `actions.enabled: false`.

- **Single deployment-wide opt-in for v2-actions CreateRun routing:**
  ```yaml
  actionsLeasor:
    enabled: true
  ```
  Setting this **(a)** routes this deployment's `UNION_ORG` through the v2 actions service and **(b)** hard-rejects sub-2.0.4 SDK CreateRun requests (legacy queue/executor decommissioning path). Default is `false` so chart upgrades don't break existing legacy-SDK users. Fresh single-tenant selfhosted envs typically flip this to `true` in their per-env overrides — no need to duplicate any `executions.configMap` block; the routing injection happens in `templates/_helpers.tpl`.

- **Deprecation timeline encoded in the chart:**
  - **2026-06-30** — queue + executor services formally deprecated. SDK <2.0.4 still works through the legacy path, but users should migrate.
  - **2026-07-31** — chart default flips to `actionsLeasor.enabled: true`; queue + executor templates are removed; the knob becomes a no-op (kept briefly for compatibility, then removed). Any env still on SDK <2.0.4 after this date will hard-fail CreateRun.

- **`alpine/k8s:1.32.3` init image promoted to a values knob** (`actions.coordination.image.*`) for air-gapped / customer-mirrored installs that need to pin or substitute the init image registry.

- **Bundled `unionoperator` image tag advances `2026.6.2 → 2026.6.3`** (chart `appVersion` follows). Standard monthly release-train bump.

### Helm chart changes (since `controlplane-2026.6.2`)

- Chart `version` + `appVersion` bumped to `2026.6.3`.
- New `templates/actions/` directory: `configmap.yaml`, `coordination.yaml`, `deployment-shard.yaml`, `service-shard.yaml`, `serviceaccount.yaml`, `_helpers.tpl` — all gated on `controlplane.enabled && actions.enabled` (default-on).
- New `templates/actions/router-*.yaml` (Envoy router fronting Actions): `router-deployment.yaml`, `router-service.yaml`, `router-configmap.yaml`, `router-hpa.yaml`, `router-cds.yaml`, `router-lds.yaml` — same gating.
- New `templates/leasor/configmap.yaml` (Leasor config keyed on dataplane cluster name) — gated on `controlplane.enabled && services.leasor`.
- New `templates/common/_grpcroute-protected.yaml` and `templates/common/_ingress-protected.yaml` shared helpers.
- New top-level value blocks in `values.yaml`:
  - `actionsLeasor.enabled: false` (deployment-wide v2-actions opt-in, see Highlights).
  - `actions.*` (~273 lines) — Actions service config, including `actions.enabled`, sharding (`totalPartitions`, `partitions`, `shardIndex`), router image, and resource limits.
  - `services.leasor` — Leasor service config.
  - `dataplaneClusterName`, two new run-service options, and the matching dataplane-side removal of two unused leaseworker values.
- `templates/_helpers.tpl` and `templates/configmap.yaml` extended to wire `actionsLeasor.enabled` into `executions.configMap.executions.apps.task.useActionsServiceForOrgs` and `rejectLegacySDKVersions` automatically.

### Image changes (appVersion `2026.6.2` → `2026.6.3`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.2` → `:2026.6.3` across every appVersion-tied workload (leaseworker, executor, operator-proxy, leasor, build-image, etc.).
- **New container surfaces (render by default)** — air-gapped / mirror-registry consumers must vendor these before upgrading:
  - **`envoy-router` image** — referenced by `templates/actions/router-deployment.yaml`. Repository + tag are configured under `actions.router.image.*` in `values.yaml`.
  - **`alpine/k8s:1.32.3` init image** — referenced by `templates/actions/coordination.yaml`. Override via `actions.coordination.image.*`.

### Migration notes

- **Upgrading without enabling routing is safe by design**: keep `actionsLeasor.enabled: false` (the default) and existing legacy-SDK clients continue to land on the queue + executor path. Plan for the new pods to appear in the namespace regardless — review CPU/memory headroom for 10 shard Deployments + router + coordination + leasor.
- **To skip the new infra footprint entirely**, set `actions.enabled: false` in your values. (Note: you'll need to re-enable it before the 2026-07-31 default flip.)
- **To opt this deployment into v2-actions routing now**, set `actionsLeasor.enabled: true`. Confirm every SDK client in the env is ≥ 2.0.4 first — older SDKs will hard-fail `CreateRun` against this deployment.
- **Air-gapped installs**: mirror `envoy-router` and `alpine/k8s:1.32.3` into your private registry before upgrading; point `actions.router.image.*` and `actions.coordination.image.*` at the mirrored locations.
- **Calendar-pin the 2026-07-31 default flip.** After that release, the legacy queue + executor templates are removed and `actionsLeasor.enabled: false` stops protecting legacy-SDK clients (any env still on SDK <2.0.4 hard-fails CreateRun).

## 2026.6.2

### Highlights

- **Bug fix: protected-ingress auth annotations are now gated on `useAuth`.** PR #293 had moved nginx auth-url annotations into the base values without a `useAuth` gate, breaking `useAuth: false` deployments (`/me` 404 → 401 → client panic). Restored support for no-auth deployments; auth-on output is unchanged (snapshots byte-identical).

### Helm chart changes (since `controlplane-2026.6.1`)

- Chart `version` + `appVersion` bumped to `2026.6.2`.
- New helper `control-plane-library.useAuth` in `templates/_helpers.tpl` (resolves `flyte.configmap.adminServer.server.security.useAuth`, defaults to `true`).
- `templates/common/_ingress-protected.yaml`, `_ingress-protected-console.yaml`, `_dataproxy-ingress.yaml`, `_usage-ingress.yaml`: every `protectedIngressAnnotations*` block is now wrapped in `{{ if include "control-plane-library.useAuth" . }}`, so the annotations only render when auth is enabled.

### Image changes (appVersion `2026.6.0` → `2026.6.2`)

- No chart-relevant image deltas on the controlplane side. See `dataplane-2026.6.2` for the `appVersion` storyline.

### Migration notes

No controlplane-specific migrations required.

If you run with `useAuth: false`, the broken auth annotations stop being emitted automatically once you upgrade — no value change needed.

## 2026.6.1

> Chart-only release: `appVersion` stays at `2026.6.0`. No image changes — see `controlplane-2026.6.0` for the image notes.

### Highlights

- **Per-cloud overlay consolidation (potentially breaking for external consumers).** The `values.{aws,gcp}.selfhosted-intracluster.yaml` overlays are **deleted**; their contents become the canonical `values.{aws,gcp}.yaml`. One canonical overlay per cloud now serves every topology (intracluster, multi-cluster same-VPC, BYOC public) — topology is decided by env-layer Service annotations and DNS, not by chart values. See **Migration notes** and `charts/MIGRATION.md`.
- **DP→CP endpoint variables collapsed into a single canonical `CONTROLPLANE_HOST`** (`DATAPLANE_ENDPOINT` → `DATAPLANE_HOST` on the CP→DP side). Existing env overlays that set the legacy names keep working unchanged via `default`-based fallback.
- **`build-image` bootstrap Job gains escape hatches** for restricted-network / GitOps deployments: `imagePullSecrets`, `annotations`, `extraEnv`, `extraVolumes`/`extraVolumeMounts`. The Job now inherits the chart-wide `imagePullSecrets` by default (fixes a potential ImagePullBackOff on registries that require auth).

### Helm chart changes (since `controlplane-2026.6.0`)

- Chart `version` bumped to `2026.6.1`; `appVersion` unchanged (`2026.6.0`) — this is a chart-only release.
- Deleted `values.aws.selfhosted-intracluster.yaml` / `values.gcp.selfhosted-intracluster.yaml`; the canonical `values.{aws,gcp}.yaml` now carry the (mode-agnostic) intracluster content. Pre-consolidation contents preserved for reference at `examples/values.{aws,gcp}.legacy.yaml`; intracluster overrides available at `examples/values.{aws,gcp}.intracluster.yaml`.
- Introduced `global.CONTROLPLANE_HOST` and `global.DATAPLANE_HOST`. The four legacy DP→CP endpoint vars (`CONTROLPLANE_INTRA_CLUSTER_HOST`, `QUEUE_SERVICE_HOST`, `FLYTEADMIN_ENDPOINT`, `CACHESERVICE_ENDPOINT`) and the legacy `DATAPLANE_ENDPOINT` all fall through to the canonical names.
- Added `charts/MIGRATION.md` (rename + variable migration story) and `charts/CONVENTIONS.md` ("we only ship overlays for configurations we actively test").
- `imageBuilder.bootstrap` gains `imagePullSecrets`, `annotations`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`.

### Migration notes

**Read `charts/MIGRATION.md` for the full story.** Summary:

- **If you fetch `values.{cloud}.selfhosted-intracluster.yaml` over HTTP** (terraform, scripts, CI): that filename now returns 404. Switch to canonical `values.{cloud}.yaml` and layer `examples/values.{cloud}.intracluster.yaml` on top if you want intra-cluster routing.
- **If you fetch `values.{cloud}.yaml`**: the contents changed (now topology-agnostic). Diff against `examples/values.{cloud}.legacy.yaml` to see exactly what moved for you.
- **Legacy host variables still work** — every consumption site uses `{{ default <canonical> <legacy> }}`, so any env still setting `CONTROLPLANE_INTRA_CLUSTER_HOST`, `FLYTEADMIN_ENDPOINT`, `DATAPLANE_ENDPOINT`, etc. is unaffected. Move to `CONTROLPLANE_HOST` / `DATAPLANE_HOST` when convenient.

No action required for the `build-image` bootstrap change — the new pull-secret inheritance is the only behavioural delta and it's a fix. Set `imageBuilder.bootstrap.imagePullSecrets: []` to opt out.

## 2026.6.0

### Highlights

- **`build-image` bootstrap Job now uses a pre-baked image.** The post-install hook previously `pip install`-ed `flyte` + `kubernetes` from PyPI on every run, which fails in restricted-network clusters. It now pulls a Union-published `build-image-bootstrap` image (tagged with the chart `appVersion`) with the tooling already baked in.
- **New `ingress.extraHosts`** to append additional controlplane hostnames (vanity domains, region cutovers) across both the nginx Ingress and the Envoy GRPC/HTTP routes in one place.
- **Billing collection now works in low-privilege mode.**

### Helm chart changes (since `controlplane-2026.5.9`)

- Chart version + `appVersion` bumped to `2026.6.0`.
- `ingress.extraHosts` (default `[]`) appends hostnames to every controlplane Ingress and Envoy GRPCRoute/HTTPRoute via a shared helper. Default `ingress.tls` is now `[]` (previously hard-coded to a `controlplane-selfsigned-tls-secret` the chart cannot provision). See **Migration notes**.
- `build-image` bootstrap Job repointed at the pre-baked `build-image-bootstrap` image. **`imageBuilder.bootstrap.image` schema changed from a string to `{repository, tag}`** to match every other image block in the chart. See **Migration notes**.
- Billing-collection wiring so usage reporting runs in low-privilege deployments.

### Image changes (appVersion `2026.5.9` → `2026.6.0`)

- The `build-image-bootstrap` image consumed by the chart's post-install hook is now published by Union, tagged with the chart `appVersion`. This is the only image delta that affects chart behaviour directly.

#### Images to vendor (delta vs `controlplane-2026.5.9`)

The `build-image` bootstrap hook (added in 5.8) now follows the same `IMAGE_REPOSITORY_PREFIX` mirror convention as `services` / `unionconsole`. Vendoring customers swap one image and gain the no-network-at-hook-runtime guarantee:

| Change | Image | Source |
|---|---|---|
| ✚ | `{{ .Values.global.IMAGE_REPOSITORY_PREFIX }}/build-image-bootstrap:{{ .Chart.AppVersion }}` (resolves to e.g. `<your-mirror>/build-image-bootstrap:2026.6.0`) | `imageBuilder.bootstrap.image` (default) |
| ✖ | `docker.io/library/python:3.13-slim` | previous default in 5.8 / 5.9 |

After this release the hook no longer reaches PyPI at runtime — `flyte` + `kubernetes` are baked into the pre-published image. Restricted-network customers can leave `imageBuilder.bootstrap.enabled: true` and just point `global.IMAGE_REPOSITORY_PREFIX` at their mirror.

`services`, `unionconsole`, and `build-image-bootstrap` all retag to `:2026.6.0`.

### Migration notes

**`ingress.tls` no longer has a chart default (potentially breaking).** Deployments that relied on the chart-default `ingress.tls` will now render without a `tls:` block. Set it explicitly in your env overlay:

```yaml
ingress:
  tls:
    - hosts:
        - '{{ .Values.global.UNION_HOST }}'
        - 'controlplane-nginx-controller.{{ .Release.Namespace }}.svc.cluster.local'
      secretName: <your-controlplane-tls-secret>
```

**`imageBuilder.bootstrap.image` is now an object.** If you overrode it as a string, update to the object form:

```yaml
# Before
imageBuilder:
  bootstrap:
    image: my-registry/my-image:tag

# After
imageBuilder:
  bootstrap:
    image:
      repository: my-registry/my-image
      tag: tag
```

**`extraHosts` on an OIDC-protected deployment** must also be added to `auth.authorizedUris`, `auth.appAuth.externalAuthServer.allowedAudience`, and the IdP application's redirect-URI list — otherwise login on the alias host fails because flyteadmin falls back to its internal service URL as the OAuth `redirect_uri`.

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
