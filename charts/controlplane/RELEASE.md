# controlplane — Release Notes

## 2026.7.3 WIP

### Removed: legacy queue service

The legacy queue service and corresponding executor has been removed from the chart,
completing the deprecation announced 2026-06-30. The actions + leasor stack is
the only execution path.

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

- **`connection.rootTenantURLPattern` default now the publicly-resolvable control-plane host.** It defaulted to the cluster-local ingress svc FQDN (`controlPlaneLibrary.ingressFqdn`), which only resolves intracluster — but this endpoint is minted into eager api-keys and dialed by **dataplane task pods** (and CP↔CP services), so a separate-cluster data plane couldn't reach it. It now defaults to `dns:///{{ .Values.global.UNION_HOST }}`. The union shared-services config and flyteadmin's config are converged on the same `global.UNION_HOST`. **Action:** none for cloud-managed envs (the generated overlay sets the topology-aware host); a standalone chart install that relied on the svc-FQDN default and runs an intracluster data plane may set `configMap.connection.rootTenantURLPattern` (and `flyte…connection.rootTenantURLPattern`) back to `dns:///{{ include "controlPlaneLibrary.ingressFqdn" . }}` via overlay.
- **Render-time guard on `connection.rootTenantURLPattern`.** The chart now fails render if the value is not a `dns:///` gRPC target or carries a trailing `:port` (control-plane services strip the `dns:///` prefix and dial the bare host, and a port corrupts the eager-api-key codec's decoded fields). No effect on valid configs.
- **Fully qualified image repository paths.** Every image the chart renders now spells out its registry host. An unqualified repository resolves against the implicit `docker.io/` default, which clusters running an allowed-registry admission policy reject with `ErrImagePull`. Changed: **`services.actions.coordination.image.repository`** → `docker.io/alpine/k8s`; **`scylla-operator.image.repository`** → `docker.io/scylladb` (new override — upstream ships the bare org, and the subchart appends `/scylla-operator`); **`scylla.scyllaImage.repository`** → `docker.io/scylladb/scylla` and **`scylla.agentImage.repository`** → `docker.io/scylladb/scylla-manager-agent` (new overrides; these land in the `ScyllaCluster` CR, so the operator rather than the kubelet does the pull). No image contents change — same digests, qualified names. A `make check-image-paths` gate (wired into `make test` and the `image-paths` CI job) now fails the build on any unqualified reference.
- **Render-time consistency guard on `rootTenantURLPattern`.** The endpoint lives in two independent values paths — the top-level `configMap.connection` (control-plane services + the EAGER_API_KEY the operator mints and data-plane task pods dial) and `flyte.configmap.adminServer.connection` (flyteadmin-private's admin clientset cache, which the flyte subchart owns and can't share via a helm `include`). The chart now fails render if they resolve to different values, so an overlay that overrides one but not the other can't silently leave flyteadmin dialing a different control-plane host than every other service. Both still default to `dns:///{{ .Values.global.UNION_HOST }}`; override them together.

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
