# dataplane — Release Notes

## Unreleased

### Configuration changes

- **Data plane overlay cleanup — remove conflicting and redundant defaults** ([#497](https://github.com/unionai/helm-charts/pull/497)). The per-cloud overlays (`values.{aws,gcp,azure}.yaml`) had accumulated settings that either restated a base default, conflicted between clouds (e.g. catalog-cache `use-admin-auth` defaulted `false` in the GCP overlay but `true` in the AWS/Azure overlays for the same kind of data plane), or belonged in the base chart because they are not cloud-specific. Those settings now live as **base `values.yaml` defaults**, and each overlay is reduced to cloud-specific config only (provider, object storage, IAM / Workload-Identity annotations, region + task-log wiring, and the cloud globals a user fills in) with a PURPOSE header documenting that contract.

  **Base `values.yaml` defaults changed:**
  - `secrets.admin.clientId` now derives from `global.AUTH_CLIENT_ID` (was a standalone `dataplane-operator` placeholder), so the single admin client id resolves from one global at every `config.*` site.
  - `storage.enableMultiContainer` now defaults `true` (metadata and fast-registration buckets differ).
  - Monitoring: `kube{ControllerManager,Scheduler,Etcd,Proxy}.enabled` and `defaultRules.rules.*` now default `false` — a data plane cannot scrape the cluster's control-plane components, so these ServiceMonitors / alerting rules would otherwise trip false-positive `TargetDown` alerts.
  - `config.union.auth.enable`, `clusterresourcesync.…auth.enable` (+ `scopes`), and catalog-cache `use-admin-auth` now default **enabled** in base (a data plane authenticates to its control plane out of the box).
  - `ingress` and `ingress-nginx` defaults now live in base (both `enabled: false`, with the class / Service / host defaults ready to switch on).
  - `secrets.admin.create` stays `true`; `controlplaneNamespace` stays `""`; `serving.auth.enabled` and `dcgm-exporter.enabled` keep their base values — the overlays no longer restate them.
  - The fluentbit `ServiceAccount` name defaults to `union-system`.
  - Billing is controlled by `config.operator.billing.model` (base default `ResourceUsage`); the inert `config.operator.billableUsageCollector.enabled` key is removed.
  - Removed dead base keys: `prometheus.prometheusOperator` (targets a key the community prometheus chart doesn't have) and empty `flytepropeller` stubs.

  **Overlay (`values.{aws,gcp,azure}.yaml`) defaults removed:** the admin `clientId` restatements; the monitoring + `enableMultiContainer` defaults; `config.union.auth.enable`, `clusterresourcesync.…auth`, and catalog-cache `use-admin-auth` (the cross-cloud conflict above); `secrets.admin`; `serving.auth.enabled`; `dcgm-exporter.enabled` (the overlays keep only their cloud-specific node affinity); `controlplaneNamespace`; `ingress` / `ingress-nginx` enablement; the task-pod `_U_EP_OVERRIDE` / `_U_INSECURE` `default-env-vars` (the leaseworker and executor already inject these from `config.union.connection`); and the dead `billableUsageCollector` / `singleTenantOrgID` keys.

- **Control-plane host: one global instead of four.** The DP→CP destination is now a single host global, `global.CONTROLPLANE_HOST` (moved to the top of the globals — it's the first thing to configure). Everything derives from it: the gRPC endpoint and the app-callback URL. Removed:
  - **`global.CONTROLPLANE_GRPC_ENDPOINT`** — `dataplane.cp.endpoint` derives `dns:///<host>` from `CONTROLPLANE_HOST`. The `:443` port is omitted; grpc-go's DNS resolver and Connect/HTTPS both default to 443.
  - **`global.QUEUE_GRPC_ENDPOINT`** and the **`dataplane.cp.queueEndpoint`** helper — the task-pod endpoint is injected by the leaseworker/executor from `config.union.connection`; there is no separate queue global. Authless / direct-service routing (skip nginx + OAuth, dial the in-cluster Service on `:80`) is configured explicitly via `config.union.auth` + `config.union.connection`, documented in the new **`examples/values.authless.yaml`**.
  - **`global.UNION_CONTROL_PLANE_HOST`** and the top-level **`.Values.host`** are now **DEPRECATED** — both are still honored as fallbacks (precedence `CONTROLPLANE_HOST` > `.Values.host` > `UNION_CONTROL_PLANE_HOST`) but should be migrated to `CONTROLPLANE_HOST`; they will be removed in a future release. `.Values.host` is the pre-globals top-level knob; no terraform-generated env sets it. The intracluster examples are simplified to just set `CONTROLPLANE_HOST`.

- **`low_privilege` is now the chart's only privilege axis; `namespaces.enabled` no longer implies single-namespace mode** (Linear UN-29; RBAC hardening phase 0). The `singleNamespace` helper — which drives RBAC kind, `limit-namespace` / `namespace_mapping` / `limitNamespace` injection, and the `clusterresourcesync` gate — was defined as `or (not namespaces.enabled) low_privilege`. That folded a namespace *pre-seed* toggle into a *privilege* decision, and the two are not the same thing: `namespaces.enabled` only pre-seeds six hardcoded namespaces (`flytesnacks-{development,staging,production}` and `union-health-monitoring-{development,staging,production}`); with it off, a fully-privileged data plane still creates namespaces for newly registered projects dynamically, via `clusterresourcesync`. `singleNamespace` is now exactly `low_privilege`, which is the one flag that really does mean "no namespaces are created by any route."

  **This fixes a silent misconfiguration in the default full-privilege install.** `namespaces.enabled` defaults to `false`, so `low_privilege: false` alone previously put the chart in single-namespace mode — and all three `clusterresourcesync` templates are gated `not singleNamespace`, so the very component whose `a_namespace` template creates per-project namespaces was suppressed. A multi-namespace data plane that left `namespaces.enabled` at its default had nothing creating namespaces for new projects at all.

  **In the `namespaces.enabled: false` + `low_privilege: false` combination only**, the deployment becomes a genuine multi-namespace one: `clusterresourcesync` renders (when `clusterresourcesync.enabled: true`); `limit-namespace` / `namespace-template` / `limitNamespace` / `namespace_mapping` are no longer pinned to the release namespace for propeller, leaseworker and nodeexecutor (propeller returns to `limit-namespace: all`); the *forced* common ServiceAccount is released — though `commonServiceAccount.enabled` defaults to `true`, so a default install still shares `union-system` and only an explicit `commonServiceAccount.enabled: false` gives each component its own (`executor`, `leaseworker`, `proxy-system`, `operator-system`, `union-webhook-system`); and the single-namespace task PodTemplate and image-builder ConfigMap are no longer emitted. This entry covers the privilege-axis change only; what that mode's RBAC now looks like is the subject of the entries below, which narrow it substantially.

  **Every `low_privilege: true` deployment is namespace-scoped exactly as before**, and pre-seeds nothing regardless of `namespaces.enabled`.

  `low_privilege` must be a **YAML boolean**, and nothing enforces it. Every gate reads the value for raw Go-template truthiness, so a quoted `"false"` is truthy and means `true` — the deployment is silently single-namespace while the values file reads false. See "Migration / action required" below; the same hazard applies to every boolean in the chart, and to `namespaces.enabled` it applies in the direction that *widens* what the release owns.

  RBAC is verified by review of committed golden artifacts: the full rendered manifests in `tests/generated/`, one per fixture. `make helm-test` fails if a snapshot is stale, so a change to the rendered RBAC has to be regenerated and reviewed in the same commit.

- **`nodeobserver.enabled: true` now installs under `low_privilege: true`, where it
  previously could not.** nodeobserver's function is watching and updating `nodes`, a
  cluster-scoped resource that no namespaced Role can convey. In the released chart the
  combination installed cleanly and then failed at runtime on the first node write — a
  DaemonSet plus a Role whose `nodes` rule the API server silently ignores. The fix is
  the grant, not a refusal: cluster slots are emitted as `ClusterRole` +
  `ClusterRoleBinding` in **every** privilege mode, so `union-nodeobserver-cluster-read`
  (`nodes: [get]`, and the `pods: [list]` below) and `union-nodeobserver-cluster-write`
  (`nodes: [update]`) are now correct under `low_privilege: true` too. Pinned by
  `tests/generated/dataplane.nodeobserver-low-priv.yaml`.

  **Its other grant reaches it in both modes as well.** The cluster-wide `pods: list` —
  needed because nodeobserver lists with an empty namespace plus a `spec.nodeName` field
  selector, which Kubernetes authorizes as a cluster-scope check — is declared in the
  `cluster-read` slot next to `nodes: [get]`, so it too is emitted whatever the privilege
  mode. `union-nodeobserver-cluster-read` carries both rules in
  `dataplane.nodeobserver-low-priv.yaml` and in `dataplane.nodeobserver-full-priv.yaml`
  alike. `nodeobserver.enabled` still defaults to `false`.

- **`flytepropellerwebhook.managedConfig: false` now installs under
  `low_privilege: true`, where it previously could not,** and its
  `mutatingwebhookconfigurations` grant no longer renders at all under the default
  `managedConfig: true`. With `managedConfig: false` the webhook registers its own
  MutatingWebhookConfiguration — cluster-scoped, and unconveyable by a namespaced Role;
  the released chart emitted a dead rule and the webhook silently received no pods. The
  `union-webhook-cluster-write` `ClusterRole` is now emitted in both privilege modes, so
  the registration works. **Note what that grant cannot be:** RBAC cannot scope `create`
  by `resourceNames`, so the rule is unbounded on
  `mutatingwebhookconfigurations` by construction — which is a reason to prefer the
  default. **The default (`managedConfig: true`) is unaffected;** under it Helm creates
  the configuration and the grant is not emitted. Pinned by
  `tests/generated/dataplane.webhook-unmanaged-config-low-priv.yaml`.

- **`commonServiceAccount.enabled` is now honored in every privilege mode.** The
  `useCommonServiceAccount` helper previously returned true whenever `singleNamespace`
  (i.e. `low_privilege`) was set, so an explicit `commonServiceAccount.enabled: false`
  was silently discarded in the chart's default mode. Identity sharing and privilege
  scope are independent concerns and are now keyed independently. **The default is
  unchanged (`true`), so no existing install is affected.** Setting it `false` creates
  one ServiceAccount per component; each new KSA name needs a matching
  workload-identity binding in the cloud repo before those workloads can authenticate.

- **Union RBAC roles are renamed and repartitioned on _where_ a grant applies.** The old
  per-component roles — `operator-system`, `proxy-system`, `union-executor`,
  `union-leaseworker`, `union-webhook-role`, `union-nodeobserver`, `flytepropeller-role`
  and `union-clustersync-resource` — no longer exist under those names. **Any external
  tooling referencing them by name must be updated.**

  Rules now live in roles named for their destination rather than for the component that
  asked for them. In the usual `union` release namespace:

  | Role | Kind | Bound | Holds |
  |---|---|---|---|
  | `union-comp-ns-read` / `union-comp-ns-write` | `Role` | `RoleBinding` in the release namespace | what union components need on union's *own* objects |
  | `union-work-ns` | `ClusterRole` (`Role` under `low_privilege: true`) | `RoleBinding` per work namespace — **never** in the release namespace under full privilege | what components need on user tasks, apps and builds |
  | `union-<component>-cluster-read` / `-cluster-write` | `ClusterRole` | `ClusterRoleBinding` | the few grants that are cluster-scoped by necessity |
  | `union-<component>-work-ns-cluster-read` | `ClusterRole` | `ClusterRoleBinding` | reads the API server authorizes as cluster-scope checks because the caller passes an empty namespace; `list`/`watch` only; not emitted at all under `low_privilege: true` |

  The three namespace-scoped roles are **pooled**: one object holding the union of every
  enabled component's rules, bound to every contributing ServiceAccount. Pooling is by
  slot, not by identity, so `commonServiceAccount.enabled: false` does not multiply the
  object count. The cluster-scoped roles stay per-component, because their blast radius
  is unbounded and precision is worth paying for there.

  Among union's non-app-serving components, only `clusterresourcesync`, the pod webhook
  and `nodeobserver` hold a `-cluster-read` / `-cluster-write` role; in zero-trust mode
  the five app-serving components hold one each, covered in "App-serving (Knative) RBAC"
  below. Unlike `-work-ns-cluster-read`, these are emitted in **both** privilege modes.
  `-work-ns-cluster-read` is broader — under `low_privilege: false`
  it is held by `executor`, `leaseworker`, `operator`, `proxy`, the pod webhook, and
  `flytepropeller` when enabled — but it is **read-only in every
  case**, and it is not emitted at all under `low_privilege: true`. See "Cluster-scoped
  reads at `low_privilege: false`" below.

  **The split is the point.** Because `union-work-ns` is never bound in the release
  namespace under `low_privilege: false`, a component that can create any Pod in a work
  namespace can no longer write union's own Deployments or read its Secrets. **Under
  `low_privilege: true` with the default `commonServiceAccount.enabled: true`, effective
  permissions per ServiceAccount are unchanged** — there the release namespace *is* the
  work namespace, so `union-work-ns` binds there; every component already ran as the one
  shared `union-system` identity and so already held the union of every component's
  rules; and the change is one of packaging only.

  **Under `low_privilege: true` with `commonServiceAccount.enabled: false` it is not
  packaging only — pooling widens each identity.** A pooled slot holds the union of every
  enabled declarer's rules and is bound to every declaring ServiceAccount, so splitting
  the identities does not split the permissions: each component now holds every other
  declarer's rules in each slot it declares into. Under `low_privilege: true`
  `union-work-ns` is bound in the release namespace, so that union lands on union's own
  objects. Measured against the per-component roles this release replaces, as rendered in
  `tests/generated/dataplane.per-component-sa.yaml`:

  | ServiceAccount | Held before | Holds now |
  |---|---|---|
  | `proxy-system` | `get`/`list`/`watch` on `events`, `flyteworkflows`, `pods`, `pods/log`, `rayjobs`, `resourcequotas` — read-only | `*/*` at the full eight-verb write set |
  | `union-webhook-system` | read + `create`/`patch`/`update` on `pods`, `replicasets/finalizers`, `secrets` | `*/*` at the full eight-verb write set |
  | `operator-system` | read + write on six named resource types, plus `flyteworkflows` and the knative serving types | `*/*` at the full eight-verb write set |

  `executor` and `leaseworker` already held `*/*`, so for them this really is packaging
  (plus `deletecollection`, below). **Per-component ServiceAccounts buy identity
  separation for cloud IAM — one workload-identity / IRSA annotation per component — not
  in-cluster RBAC separation.** Under `low_privilege: false` the components-namespace /
  work-namespace split above is real regardless of how the identities are arranged, but
  the pooling within each slot is the same: `commonServiceAccount.enabled: false` is not
  a way to narrow what any one component can do inside a namespace it already reaches.
  Pooling is a deliberate design decision — one object per destination is what makes the
  destination axis reviewable — and this note exists so nobody reads split identities as
  an RBAC narrowing they are not.

  **One verb is new across the board: `deletecollection`.** A pooled slot has a single
  emitter-owned verb set — `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`,
  `deletecollection` — where the old per-component write buckets each named a shorter
  list of their own. Under `low_privilege` the shared identity's `*/*` rule was
  `create`, `delete`, `patch`, `update`; only the operator's `flyteworkflows` rule carried
  `deletecollection`. Every identity that writes in a namespace now holds
  `deletecollection` there — the release namespace under `low_privilege: true`, the work
  namespaces under `low_privilege: false`. It conveys nothing that `list` plus `delete`
  does not already convey in combination, and it is called out only because it is the one
  grant that is added everywhere rather than moved.

- **BREAKING: no union role is bound cluster-wide to reach work namespaces any more,
  under `low_privilege: false`.** `union-work-ns` still renders as a `ClusterRole`, so its
  rules are written once rather than duplicated per namespace, but every binding the chart
  emits for it is a namespaced `RoleBinding` — and a `RoleBinding` referencing a
  `ClusterRole` scopes that role's rules to the binding's own namespace. Union components
  therefore no longer hold `get` on every Secret in the cluster, in any configuration.

  **This is a real narrowing of what a `low_privilege: false` deployment can reach, and it
  requires action:** something must now create a `union-work-ns` `RoleBinding` in each work
  namespace. There are three ways to arrange that, and they are mutually exclusive:

  - **Runtime** — `clusterresourcesync.enabled: true`. It creates the binding as it
    provisions each namespace, from a template this chart generates. This is the right
    posture when projects are registered at runtime.
  - **Static** — `namespaces.enabled: true` with a non-empty `namespaces.static`. This
    chart emits one `RoleBinding` per listed namespace.
  There is also a third arrangement the chart does not model: if your own tooling
  provisions work namespaces, it must create the binding alongside them. Leave both keys
  above at their defaults; there is nothing to set.

  **The chart cannot verify that anything actually creates them, and does not check.**
  If nothing does, the install renders green and task pods fail with `Forbidden` at their
  first execution rather than at deploy. See "Migration / action required", and the
  README's
  "RBAC: how union workloads reach work namespaces" for the full posture comparison.

- **`namespaces.static` (new) enumerates the work namespaces to pre-create and to bind
  `union-work-ns` into, when `namespaces.enabled: true` (see below).** It defaults to the
  six names `common/namespaces.yaml` previously hardcoded. By itself this default is
  inert: `namespaces.enabled` defaults `false`, so a default install emits no
  per-namespace RoleBindings regardless of what this list contains. Under
  `low_privilege: false` **with `namespaces.enabled: true`** the chart emits exactly one
  `RoleBinding` per listed namespace — `union-work-ns` is a single pooled role, so the
  count does not grow with the number of components or with
  `commonServiceAccount.enabled: false` — and union components then hold work-namespace
  permissions only in these namespaces. **This is not the full set a dataplane uses** —
  `clusterresourcesync` creates one namespace per project/domain at runtime and cannot
  know those names in advance, so enumerating this list is only appropriate when work
  namespaces are provisioned ahead of time. **The shared `union-system` identity is not
  fully confined by this alone:** with `fluentbit.enabled: true` (the default),
  fluent-bit runs as the same ServiceAccount and holds its own read-only cluster-wide
  grant (`get`/`list`/`watch` on `namespaces`/`pods`) for log shipping, independent of
  `namespaces.static`.

- **`namespaces.enabled` now also gates the per-`namespaces.static` RoleBindings
  described above, not just Namespace object creation.** The two were previously
  independent: `namespaces.enabled` only pre-seeded the six hardcoded namespaces, and
  said nothing about whether union roles were bound into them. They are now one
  decision, expressed as one flag next to the list it governs — the chart only asserts
  reach into namespaces it creates (or that an operator has told it, via this same
  flag, are otherwise already there). **`namespaces.enabled: true` keeps its existing
  meaning and gains this second one**: an overlay that already sets it will gain
  RoleBindings into the namespaces it was already creating, and switches that deployment
  from the runtime posture to the static one. The two are mutually exclusive, so confirm
  `namespaces.static` really does list every namespace your workloads use before setting
  it. `namespaces.enabled: true` with an **empty** `namespaces.static` now fails the
  render rather than producing a deployment that can reach nothing.

- **`namespaces.create` (new, default `true`) is the supported path for
  externally-managed namespaces.** It is consulted only when `namespaces.enabled: true`.
  Set it `false` when Terraform, a platform team or anything else owns the `Namespace`
  objects: you still get the per-namespace RoleBindings, and Helm never touches the
  Namespace objects, so there is no ownership to negotiate. Without this key the only way
  to have Helm manage a namespace it did not create is to annotate it for adoption
  (`meta.helm.sh/release-name`, `meta.helm.sh/release-namespace` and the
  `app.kubernetes.io/managed-by` label, set by hand first); `namespaces.create: false`
  makes that unnecessary. If a listed namespace does not actually exist, the RoleBinding
  fails to apply with `namespaces "<name>" not found` at install or sync time — loud and
  immediate, which is what makes this safe to offer.

- **In the static posture `clusterresourcesync` holds no cluster-wide grant at all.**
  With `namespaces.enabled: true` and a non-empty `namespaces.static`, the component
  renders **none of its own cluster-scoped rules**: it reaches the listed namespaces
  through the same `union-work-ns` RoleBindings every other component uses. That is the
  posture's whole security argument. (One cluster-scoped object remains in every posture:
  the `ClusterRoleBinding` to the built-in `system:auth-delegator` `ClusterRole`, required
  for apiserver auth delegation and emitted whenever `clusterresourcesync.enabled` is
  true. This chart does not define that `ClusterRole`, so it sits outside the model
  entirely. Setting `clusterresourcesync.clusterRoleRules` yourself also puts a
  cluster-scoped role back, holding exactly the rules you named.) **In the runtime posture
  the grant is three narrow rules** — `get`, `create`,
  `patch` on `namespaces` and on `rolebindings`, plus `bind` on the single
  `union-work-ns` `ClusterRole` by name. `delete` is added to the `namespaces` rule only
  when `clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace: true`.

- **`clusterresourcesync` now creates the per-work-namespace RoleBindings.** In the
  runtime posture the chart generates an `ab_union_rolebinding.yaml` entry into
  `clusterresourcesync`'s template ConfigMap, alongside the built-in `a_namespace`,
  `b_default_service_account` and `c_project_resource_quota` templates. Nothing needs
  adding to `clusterresourcesync.additionalTemplates` by hand. The `ab_` key sorts the
  binding immediately after `a_namespace` and before the ServiceAccount and ResourceQuota
  templates, which is load-bearing: `clusterresourcesync` reaches a new namespace
  *through* `union-work-ns`, so the binding must exist before the objects that depend on
  it. Both the grant and the template are rendered into `tests/generated/`, so a drift
  between them is a reviewable diff.
- **The `a_namespace` template is dropped when `clusterresourcesync` is confined to
  `namespaces.static`.** In that posture it holds no `namespaces` permission by design,
  and pre-creating the namespace does not make reconciling it authorized — the create is
  a cluster-scoped attribute check and returns `Forbidden` — on every project namespace,
  on every sync cycle, forever, since the template checksum is only cached on success.
  At flyteadmin's default `BatchSize: 10` the batched sync path logs each namespace's
  error and continues, so other projects and the remaining templates still apply and
  this is persistent error noise plus a permanently climbing `ResourceAddErrors` metric
  rather than an outage. **If you set `clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.batchSize: 0`
  it becomes an outage**: zero selects serial processing, where the first namespace error
  aborts the remaining projects for that cycle.
  **Affects only a non-empty `namespaces.static` + `namespaces.enabled: true`**, which
  is new in this release.
- **Namespaces created from `namespaces.static` now carry
  `helm.sh/resource-policy: keep`, so `helm uninstall` no longer deletes them.**
  Previously uninstalling the release cascade-deleted each managed namespace and
  everything inside it — task pods, Secrets, PVCs, and objects `clusterresourcesync`
  created at runtime that this chart never knew about. That is the ordinary
  consequence of Helm owning a resource, but the resource is a whole namespace, which
  made it the largest blast radius in the chart and rarely what "uninstall the
  dataplane" was meant to mean. **Action if you relied on uninstall cleaning these up:**
  delete them with `kubectl` instead. Helm still owns them for install and upgrade; only
  delete changes.

  **If your namespaces are created outside this chart, set `namespaces.create: false`
  instead of annotating them for Helm adoption.** That is now the supported path: you get
  the RoleBindings and Helm never touches the Namespace objects. The adoption dance below
  is only for namespaces this chart already created.

  **One workflow this makes harder — renaming the release.** Uninstall
  leaves the namespaces *and* their Helm ownership annotations, so reinstalling under
  the same release name adopts them cleanly, but reinstalling under a *different* name
  fails with `invalid ownership metadata … key "meta.helm.sh/release-name" must equal`.
  **Transfer ownership rather than deleting the namespaces** — deleting them destroys
  the workload data this annotation exists to protect:

  ```bash
  kubectl annotate namespace <ns> \
    meta.helm.sh/release-name=<new-release> \
    meta.helm.sh/release-namespace=<release-namespace> --overwrite
  kubectl label namespace <ns> app.kubernetes.io/managed-by=Helm --overwrite
  ```

  (Both the failure and this procedure verified on k3s 1.35, including that a ConfigMap
  in the namespace survives the transfer.)
- **A `low_privilege: false` data plane now needs a route into its work namespaces.**
  With `union-work-ns` no longer bound cluster-wide, arrange one of:
  `clusterresourcesync.enabled: true`, or `namespaces.enabled: true` with a non-empty
  `namespaces.static`, or your own tooling creating the `union-work-ns` RoleBinding in
  each work namespace as it provisions them.

  **The render does not fail if you arrange none of them.** The chart cannot detect
  tooling outside itself, so it does not try to police this; union workloads simply hold
  `union-work-ns` in the release namespace and nowhere else, and task pods fail with
  `Forbidden` at their first execution. Watch for a second symptom too: at the default
  `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled: true` the pod
  webhook mirrors image-pull secrets into each work namespace, and without the binding
  that copy fails silently — the pod is admitted without its credential and then fails
  with `ImagePullBackOff`, which reads as a registry problem. See the README's
  "Provisioning the binding yourself" and "Diagnosing a missing binding".
- **`namespaces.static` now rejects the release namespace** when `namespaces.enabled: true`.
  Naming it would bind `union-work-ns` in the components namespace, silently collapsing the
  split this model exists to create — union components would regain write access to union's
  own Deployments and Secrets with nothing in the render to show it. That now fails the
  render. **Inert lists are unaffected** — the check is gated on `namespaces.enabled`, so an
  overlay carrying a harmless stale entry still upgrades. Duplicate entries are *not*
  rejected: the render succeeds and emits the same `Namespace` and the same `RoleBinding`
  twice. De-duplicate the list yourself.
- **`nodeobserver`'s `pods: list` moves into a cluster-scoped role.** It lists pods
  with an empty namespace plus a `spec.nodeName` field selector, which Kubernetes
  authorizes as a cluster-scope check — no number of per-namespace RoleBindings can
  satisfy it, so once work-namespace grants were bound only per namespace the rule had to
  move. It is emitted as part of `union-nodeobserver-cluster-read`, a `ClusterRole` +
  `ClusterRoleBinding` present in both privilege modes, which is the only shape that
  works. **No net privilege change**: it reached the same pods through the cluster-wide
  binding before.
- **The pod webhook now requires reach into work namespaces when image-pull secret
  mirroring is enabled.** With none of the three postures configured, the webhook cannot
  create the mirrored secret, and the resulting `Forbidden` is swallowed rather than
  surfaced — pods are admitted without their secret and fail later with
  `ImagePullBackOff`. The render now fails instead, naming all three routes. Pick one, or
  disable image-pull secret mirroring.
- **BREAKING: `clusterresourcesync.clusterRoleRules` now defaults to `[]` and rejects
  `verbs: ['*']`.** Its previous default was twelve resource types at `verbs: ['*']`. The
  grants the component needs for its own job are now **derived** from what it actually
  does, and are emitted whether or not this key is set; the key remains as an extension
  point for **additional** resource types your own `clusterresourcesync.templates` /
  `additionalTemplates` entries create — a custom resource, say. Rules set here go through
  the same verb allowlist as every other cluster-scoped grant in this chart: `get`,
  `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`. `*` is
  rejected, and so are `escalate`, `impersonate` and `bind`. **An overlay that carries the
  old default forward is a hard render failure, not a silent narrowing** — see "Migration
  / action required" below for what to do.

  **The key is inert under `low_privilege: true`, which is the chart default, and nothing
  says so at render time.** `clusterresourcesync` is gated off entirely in that mode —
  task pods run in the release namespace and no per-project namespaces are created — so
  it contributes no roles at all and the rules set here produce no object. No grant is
  lost, because the component is not running; but an operator who sets the key on a
  default install gets silence rather than an error. Set `low_privilege: false` (with
  `clusterresourcesync.enabled: true`) if you need it. In the static posture
  (`namespaces.enabled: true`) it is *not* inert: it re-emits the
  `union-clusterresourcesync-cluster-write` `ClusterRole` and `ClusterRoleBinding` in the
  one posture that otherwise has neither — pinned by
  `tests/values/dataplane.static-ns-clusterrules.yaml`.

### Cluster-scoped reads at `low_privilege: false`

`nodeobserver` is not the only component that reads with an empty namespace, and this
release grants each of the others a role of the same shape — a per-component,
**read-only** `ClusterRole` + `ClusterRoleBinding` named
`union-<component>-work-ns-cluster-read`, holding `list` and `watch` and nothing else —
differing only in that theirs is confined to `low_privilege: false`, where
`nodeobserver`'s pod read is in a plain `cluster-read` role emitted in both modes.
**None of them is emitted under `low_privilege: true`, which is the chart default.**

**Why they are needed.** At `low_privilege: false` the chart writes no `limit-namespace`,
because work namespaces are created as projects are registered and are not known when
Helm renders. The components' controller-runtime and client-go caches therefore watch
with an empty namespace, and Kubernetes evaluates a namespace-less `LIST`/`WATCH` as a
**cluster-scope** authorization check. Per-namespace `RoleBinding`s cannot satisfy it at
any count: the call returns `403` rather than a filtered subset, and the cache never
syncs. In most cases that is a startup failure; in the webhook's case it is worse, and is
called out separately below.

| Component | Cluster-wide `list`, `watch` on | Emitted when |
|---|---|---|
| `executor` | `pods`, `podtemplates`, `namespaces` | `executor.enabled` (default) |
| `leaseworker` | `pods`, `podtemplates` | `leaseworker.enabled` (default) |
| `operator` | `pods`, `resourcequotas` | `operator.serviceAccount.create` (default) |
| `operator` | `podtemplates`, `serving.knative.dev/services`, `configurations`, `revisions` | also `apps.enabled` (default) |
| `operator` | `namespaces` | also `imageBuilder.enabled` (default) |
| `operator` | `metrics.k8s.io/pods` (`list` only) | `operator.serviceAccount.create` (default) |
| `proxy` | `pods`, `resourcequotas`, `events.k8s.io/events`, `ray.io/rayjobs` | `proxy.serviceAccount.create` (default) |
| `flytepropeller` | `pods`, `podtemplates`, `flyte.lyft.com/flyteworkflows` | `flytepropeller.enabled` (off by default) |
| `webhook` | `secrets` | `flytepropellerwebhook.enabled` (default) **and** `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled` (default) |

(`nodeobserver`'s cluster-wide `pods: list` is not in this table: it lives in
`union-nodeobserver-cluster-read`, which is emitted in both privilege modes.)

**This is a narrowing, not a widening.** The released chart bound `union-leaseworker` —
`apiGroups: ['*']`, `resources: ['*']`, at `get,list,watch,create,update,delete,patch` —
to union's ServiceAccount with a `ClusterRoleBinding` at `low_privilege: false`, together
with `operator-system`, `proxy-system` and `union-webhook-role`. Everything in the table
above is a read-only subset of what those already conveyed. There are no wildcards in any
of the new roles, and no write verb of any kind.

**The pod webhook's cluster-wide `secrets` read deserves a direct look.** The webhook
mirrors image-pull secrets into each work namespace, and to decide whether a mirror
already exists it reads the Secret **in the admitted pod's namespace** through a
controller-runtime cache built with no namespace restriction. Three things follow:

1. **It cannot be scoped from the chart.** The only knob is the propeller
   `limit-namespace`, which this chart does not set at full privilege.
2. **Scoping the cache to the webhook's own namespace would break mirroring, not narrow
   it.** controller-runtime answers a lookup outside a scoped cache with `unknown
   namespace for the cache` — a plain error, not `NotFound` — so the webhook would fail
   admission for every task pod outside the release namespace.
3. **Withholding the grant fails silently.** The cache retries a `Forbidden` `LIST`
   forever, so the webhook hangs before registering its handlers; the container has no
   readiness probe, so the pod reports `Ready` and is never restarted, while
   `failurePolicy: Fail` rejects every pod labelled `inject-flyte-secrets`.

   The released chart already grants this ServiceAccount cluster-wide `secrets` at
   `get,create,update,patch,list,watch` via `ClusterRoleBinding/union-webhook-binding`,
   so this is a strict reduction. **If you would rather not have it at all, set
   `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled: false`** —
   the webhook then uses a direct client, the `ClusterRole` is not emitted, and the cost
   is that managed-image pull secrets are no longer mirrored.

**`metrics.k8s.io/pods` is billing, not telemetry.** The usages aggregator feeds the
resource-usage billing queue whenever `billing.model` is `ResourceUsage` (the chart
default) or `Shadow`, or `collectUsages.enabled` is set, and its first act is a `List` of
pod metrics with the namespace hard-coded to "all" — it honours no `limit-namespace`, so
it is a cluster-scope read however the chart is configured. Without the grant it returns
before producing anything and retries **every 15 seconds indefinitely** — the loop stops
only when `dependenciesStatus.requiredForHealth` is set, which this chart never sets and
which defaults to false — so **no resource-usage billing data is collected, for as long as
the grant is missing**. It is not silent: each failing round logs a warning and increments
the operator's `run_errors` Prometheus counter under the `usages_aggregator` subscope,
which this chart already scrapes and which you can alert on. But there is no crash, no
`CrashLoopBackOff` and no failed release, so without that alert nothing surfaces. The
released chart conveyed this through `operator-system`'s `pods` at a wildcard apiGroup.
The rule is
ungated, because the binary's condition is a disjunction of two chart values and an
under-gate is invisible while the over-grant is negligible — pod metrics are aggregate CPU
and memory numbers with no object contents, and the rule is `list` with no `watch`.

**Deliberately not granted:**

- Cluster-wide `namespaces` for `flytepropeller`'s workflow garbage collector. It
  enumerates namespaces through a **direct** client, so without the grant it logs an error
  each cycle and collects nothing; startup is unaffected and the component is off by
  default. The `executor`'s equivalent sweep *is* granted: its list is cache-backed, so
  withholding it leaves a permanently blocked goroutine and a 403 reflector loop rather
  than a clean per-round error. (When that trade was made, the shared identity already
  held cluster-wide `namespaces` reads from the FluentBit subchart, so granting the
  executor's sweep cost nothing at defaults. FluentBit's `ClusterRole` is removed in this
  release — see "Third-party subchart RBAC" below — so the grant now stands on the
  cache-vs-direct-client difference alone, which is still the reason for it.)
- Cluster-wide `configmaps` for the `operator`. See the connector-runtime app known issue
  under Migration / action required — the read is release-namespace-targeted and reaches
  cluster scope only because the manager's cache is unscoped, which is a defect in the
  binary rather than a grant this chart should widen to accommodate.
- The task-plugin CRDs (Spark, Dask, Kubeflow, and Ray beyond the proxy's dashboard
  lookup). No enabled plugin watches them.

### Third-party subchart RBAC

Everything above concerns union-authored RBAC. This release settles the dependency
subcharts too, and writes the intended disposition of each one into `values.yaml` and
`README.md` — the artifact that was missing, and the reason the same questions kept being
re-derived and answered differently.

**The rule, stated so it stops being re-derived:** `low_privilege: true` means
union-authored components hold namespaced Roles in a single namespace. It has never meant
the chart emits zero `ClusterRole`s, and it cannot — `kube_node_*`, `kube_namespace_labels`
and the cAdvisor `container_*` families are cluster-scoped by nature and are among the
metrics this chart exists to ship. Third-party observability components are allowed
cluster-scoped **read**; they are not allowed writes, `secrets`, or any rule that does not
trace to a metric or feature in use.

**This increases cluster-scoped RBAC objects, from 2 to 4 on AWS/Azure and from 0 to 4 on
GCP, and that is the point.** The metrics in question do not work in *any* posture today:

- **kube-state-metrics has held zero permissions since 2026-05-02.** Its RoleBinding named
  `<release>-prometheus-kube-state-metrics`; the ServiceAccount is
  `<release>-kube-state-metrics`. The `-prometheus-` infix is release-name-independent, so
  it was wrong for every install. No `kube_*` series have been produced by this instance in
  three months.
- **prometheus's scrape permissions were a `ClusterRole` copied verbatim into a `Role`.**
  `nodes`, `nodes/proxy` and `nodes/metrics` are cluster-scoped, so the API server accepted
  the rule and never matched it: `kubernetes-cadvisor` has been getting `403`s, and
  `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes` were never
  collected, though the dashboards reading them shipped. At `low_privilege: false` the
  template did not render at all (UN-29), so prometheus held nothing by a second,
  independent mechanism.

What changes is the character of the grants rather than their number. The two that go away
were held by `union-system`, shared with six other workloads, and justified by nothing. The
four that arrive are held by dedicated ServiceAccounts, are read-only, contain no
`secrets`, and are written by the subcharts rather than by us.

- **prometheus: `rbac.create: true`, and `templates/prometheus/rbac.yaml` is deleted.** The
  hand-written Role was a copy of the upstream `ClusterRole` with the kind changed, so
  reverting is strictly narrower than what the chart *intended*: 4 rules over 11 resources,
  all read-only, replacing 31 rules over 32 resources that included `secrets`. This also
  restores `nonResourceURLs: ["/metrics"]`, which a namespaced Role cannot carry, and fixes
  UN-29 by construction.

  **The `ClusterRole` name is a fixed string, so one dataplane per cluster is the supported
  model.** A second install in another namespace fails on Helm ownership rather than
  silently adopting the first release's binding. The subchart emits
  `clusterRoleNameOverride` literally, so the namespace cannot be worked into it from the
  chart; the GitOps layer can override it if a cluster ever needs two.

- **Nine upstream scrape jobs are removed** — `kubernetes-apiservers`, `kubernetes-nodes`,
  `kubernetes-nodes-cadvisor`, `kubernetes-service-endpoints`(`-slow`),
  `kubernetes-services`, `kubernetes-pods`(`-slow`) and `prometheus-pushgateway`. They
  scrape every pod, service, endpoint and node in the cluster and produce nothing the
  metrics gateway admits or any dashboard reads. They were inert only because prometheus
  held no cluster-scoped read; restoring the `ClusterRole` without removing them would have
  switched cluster-wide scraping on.

- **`gpu-metrics` now discovers in the release namespace.** Its selector read
  `dcgm-exporter.namespace`, defaulting to `kube-system`, but the subchart deploys into the
  release namespace and reads `namespaceOverride` — so the job has been pointed where its
  target never was. The now-inert `dcgm-exporter.namespace` key is removed. A
  separately-managed dcgm-exporter elsewhere in the cluster is not scraped.

- **kube-state-metrics uses its own RBAC**, with `rbac.useClusterRole: true` and **6 of 28
  collectors** — `pods`, `nodes`, `namespaces`, `deployments`, `daemonsets`,
  `resourcequotas`, exactly those feeding gateway-admitted series, all `list`/`watch`.
  `useClusterRole` is required, not a preference: `nodes` and `namespaces` are
  cluster-scoped. Dropping the other 22 removes `secrets` from the pooled Role, which the
  prometheus server had been inheriting because both ServiceAccounts were bound to it. The
  dead `prometheus.kube-state-metrics.metricRelabelings` key is removed — no chart in the
  dependency tree reads it; the filter that runs is the scrape job's
  `metric_relabel_configs`.

- **FluentBit: `rbac.create: false`.** The subchart's cluster-wide `get`/`list`/`watch` on
  `namespaces` and `pods` serves a `[FILTER] Name kubernetes` stanza, and this chart has
  never configured one — `existingConfigMap` replaces the subchart's config, and the union
  config's filter section renders `fluentbit.additionalFilters` and nothing else. Metadata
  comes from the log file path and the resulting tag is the object key. `git log -S'FILTER'`
  over the whole history of the FluentBit templates returns nothing, so this has held since
  persisted logging shipped in April 2025. This removes the only third-party cluster-scoped
  RBAC in a default AWS/Azure install.

- **ingress-nginx is scoped to the release namespace by default** (`rbac.scope: true` +
  `controller.scope.enabled: true`), replacing a cluster-wide reader of `secrets`,
  `configmaps`, `pods`, `endpoints` and `nodes` with a namespaced Role. See Migration below.

- **`opencost`, `metrics-server` and `kube-prometheus-stack` are accepted as they are**, and
  documented rather than changed. None has a values lever that helps: opencost prices the
  whole cluster; metrics-server is structurally cluster-scoped and additionally writes a
  RoleBinding into `kube-system` (a hardcoded literal — so a namespace-confined operator
  gets a `403` from `helm upgrade`); kube-prometheus-stack's operator holds cluster-wide
  `secrets: '*'` and is off in every values layer and deprecating.

- **`dcgm-exporter` needs nothing** and gets nothing. Its three widening flags
  (`kubernetes.enablePodLabels`, `kubernetes.enablePodUID`, `kubernetesDRA.enabled`) are
  documented, including that `kubernetes.rbac.create: false` is only a partial opt-out —
  `kubernetesDRA.enabled` grants the `ClusterRole` outside that conjunct.

**Fixtures for `metrics-server`, `opencost` and `ingress-nginx` are added.** All three were
enabled by no fixture, so their RBAC appeared in no snapshot and could change on a subchart
bump with nothing to review. `dataplane.cost.yaml` looks like opencost coverage but sets
`opencost.enabled: false`, and `dataplane.aws.with-ingress.yaml` exercises `ingress.enabled`
rather than the subchart — so judge coverage from what a snapshot contains, not from a
fixture's name.

### App-serving (Knative) RBAC

**Everything in this subsection applies only when `zero_trust.enabled: true` and
`apps.enabled` is not `false`.** A dataplane that does not run app serving is unaffected
by all of it. The full per-component breakdown is in the README under
[App serving RBAC](README.md#app-serving-rbac); this is the change and the action.

- **BREAKING: the vendored Knative RBAC is deleted, and the app-serving components
  declare into this chart's slot framework instead.** 16 hand-vendored RBAC objects and
  the 3 ServiceAccounts they named are removed. What that retires, in the terms that
  matter:

  | Retired | What it conveyed |
  |---|---|
  | `knative-serving-core` `ClusterRole` | cluster-wide `get,list,create,update,delete,patch,watch` on `secrets`, `pods`, `namespaces`, `serviceaccounts`, `configmaps`, `endpoints`, `services` and `events`; the same seven verbs on `apps/deployments`(+`/finalizers`), both webhook-configuration kinds, `apiextensions` CRDs, `autoscaling` HPAs, `coordination` leases, `caching.internal.knative.dev/images` and cert-manager's `certificates`/`issuers`/`clusterissuers`/`certificaterequests` + `acme` challenges; those seven plus `deletecollection` on `*`, `*/status` and `*/finalizers` across `serving.knative.dev`, `autoscaling.internal.knative.dev` and `networking.internal.knative.dev`; unscoped `update` on `namespaces/finalizers`; `create` on `endpoints/restricted`; `delete` on one named `ClusterRole` |
  | `knative-serving-admin` (aggregation shell) | **any** `ClusterRole` anywhere in the cluster labelled `serving.knative.dev/controller: "true"`, conveyed to the `controller` ServiceAccount |
  | `knative-serving-aggregated-addressable-resolver` (aggregation shell) | the same, for `duck.knative.dev/addressable: "true"` |
  | `net-kourier` `ClusterRole` | cluster-wide `get,list,watch` on `pods`, `endpoints`, `services`, `secrets`, `configmaps`; leases CRUD; `patch` on ingresses and `update` on their status; `create,update,patch` on events |
  | `knative-serving-activator` (`Role`) + `knative-serving-activator-cluster` | the activator's namespaced Secret/ConfigMap reads and its cluster-wide `services`/`endpoints`/`revisions` reads |
  | `knative-serving-namespaced-admin` / `-edit` / `-view` | Knative Serving objects to anyone holding the built-in `admin`, `edit` or `view` role in a namespace, by aggregation |

  **What replaces them** is five per-component `union-knative-<component>-cluster-read`
  `ClusterRole`s — `list`/`watch` informer reads, plus two `get`-only rules: the
  controller's on `serviceaccounts`/`secrets` at `low_privilege: false` (see below) and
  the webhook's on the release `Namespace`, `resourceNames`-scoped to that one name —
  plus exactly one cluster-scoped write
  role: `union-knative-webhook-cluster-write`, whose two rules are both
  `resourceNames`-scoped (to the three knative webhook configurations, and to the release
  namespace's `namespaces/finalizers`). There is no cluster-scoped `create` anywhere in
  the set, no aggregation, and no cert-manager, CRD or HPA grant at all. The one
  cluster-wide Secret grant that remains is called out separately below.

  These roles are emitted in **both** privilege modes, unlike the
  `-work-ns-cluster-read` family — the components' informers watch cluster-wide
  regardless of `low_privilege`.

- **BREAKING (pod identity): the app-serving workloads now run as `union-system` at the
  chart default.** They previously ran as dedicated `controller` (shared by the
  controller, webhook, autoscaler and the now-removed autoscaler-hpa), `activator` and
  `net-kourier` ServiceAccounts in *every* configuration —
  the vendored manifests hard-coded those names and never consulted
  `commonServiceAccount.enabled`. Five per-binary ServiceAccounts now exist
  (`knative-controller`, `knative-webhook`, `knative-autoscaler`, `knative-activator`,
  `net-kourier`) and all five honour that flag, so at the default `true` they collapse
  onto `union-system` and Helm renders one object. **No action unless you bound external
  policy (e.g. a cloud IAM trust, an admission policy, an audit filter) to the old
  ServiceAccount names** — `system:serviceaccount:<release-ns>:controller`, `:activator`
  or `:net-kourier`. Note that `commonServiceAccount.enabled: false` does not restore
  those names: it produces the five new ones, each needing its own workload-identity
  binding.

- **`net-kourier` keeps a cluster-wide `secrets` `list`/`watch`, deliberately and
  temporarily.** Kourier registers its Secret informer unconditionally and unfiltered by
  namespace in the image this chart ships, so a cluster-scoped read is load-bearing
  today; a namespaced `Role` cannot authorize a cluster-scoped `LIST`. Withholding it
  fails silently — the reflector never syncs, the reconcilers never start, the xDS
  readiness probe stays green, and new app deployments hang at `IngressNotConfigured`
  with the controller at `1/1 Running`. **UN-39 gates that informer behind
  `KOURIER_ENABLE_INGRESS_TLS`; once the image carries the gate the grant becomes
  conditional and is removed by default.** It is narrower than the vendored
  `net-kourier` `ClusterRole` it replaces, which also held `get`.

- **`knative-controller` holds cluster-wide `get` on `serviceaccounts` and `secrets` at
  `low_privilege: false` only.** Digest resolution reads the app namespace's
  ServiceAccount and the Secrets its `imagePullSecrets` name. `get` only — no `list`, no
  `watch`. Under `low_privilege: true` the app namespace is the release namespace, so the
  read is namespaced and the rule is not emitted.

- **Three grants the vendored RBAC carried are kept, because the code that consumes them
  is still here.** They are the reason the pared-down set is not smaller still:

  | Kept grant | Consumer | What its absence does |
  |---|---|---|
  | `apps/deployments` `list`/`watch`, cluster-wide, on `knative-controller` and `knative-autoscaler` | the revision reconciler's unfiltered Deployment informer, and the KPA reconciler's `podscalable` duck informer, which LISTs `apps/v1` deployments with no namespace | `sharedmain` starts informers before serving health probes, so a `Forbidden` reflector leaves the pod permanently un-Ready and nothing reconciles. The deployment *writes* stay namespaced, in `union-work-ns` |
  | `namespaces` `get`, `resourceNames`-scoped to the release namespace, on `knative-webhook` | the namespace-ownership `Get` all three admission controllers perform each reconcile — a direct client call, not an informer | the reconcile fails before its `Update`, so the `caBundle` is never injected. On a cold install the two `failurePolicy: Fail` webhook configurations then reject every `serving.knative.dev` / `autoscaling.internal.knative.dev` / `networking.internal.knative.dev` write, including the controller's own, while the webhook pod stays `1/1 Running` |
  | `secrets` in `knative-activator`'s `comp-ns-read` (release namespace, `get`/`list`/`watch`) | the namespaced Secret informer `pkg/activator/certificate` registers at import time; registration is unconditional even though the cert cache it feeds is inert without `system-internal-tls` | the activator waits on a cache that cannot sync. Only reachable at `low_privilege: false` **and** `commonServiceAccount.enabled: false`; in the other postures a pooled slot supplied it anyway. Pinned by `tests/generated/dataplane.zero-trust-full-priv-per-component-sa.yaml` |

- **Per-component ServiceAccounts separate these five in the cluster dimension only.**
  The `-cluster-read` roles are genuinely different from one another, and
  `tests/generated/dataplane.zero-trust-per-component-sa.yaml` makes that observable. The
  namespaced slots are pooled exactly as everywhere else in this chart, so each of the
  five also receives every other declarer's rules — including union's own components'.
  As rendered: `knative-webhook` holds the full eight-verb write set on `secrets` in the
  release namespace via `union-comp-ns-write`, and `knative-controller`,
  `knative-autoscaler` and `net-kourier` are subjects of `union-work-ns`, whose first
  rule is `apiGroups: ["*"]`, `resources: ["*"]` at that same write set. `knative-activator`
  is the exception: it is a subject of `comp-ns-read` and of neither write slot.

- **BREAKING: `autoscaler-hpa` is removed.** Union app serving is KPA-only: it sets
  `min-scale`, `max-scale`, `metric`, `target` and `window`, but never
  `autoscaling.knative.dev/class`, so the HPA-class autoscaler was never exercised. The
  workload, its `gateway.components.autoscaler-hpa` values block, and the cluster-wide
  `autoscaling/horizontalpodautoscalers` grant it relied on are all gone — removing the
  workload is what makes that grant's removal permanent, since no slot declaration has to
  re-add it. **If your overlay sets `gateway.components.autoscaler-hpa.*`, the key is now
  inert** — remove it.

- **BREAKING: Knative TLS certificate provisioning is removed, and enabling it now fails
  the render.** The `config-certmanager` ConfigMap and the `routing-serving-certs`
  `Certificate` are deleted, along with the cert-manager RBAC. TLS terminates at the
  Envoy gateway. Knative registers its cert reconciler when any of six
  `gateway.config.network` settings is on — `external-domain-tls`,
  `cluster-local-domain-tls`, `system-internal-tls`,
  `namespace-wildcard-cert-selector`, and the legacy aliases `auto-tls` and
  `internal-encryption` — and then hard-fails at startup if the cert-manager CRDs are
  absent, so the chart errors at template time naming the key you enabled rather than
  leaving it silently inert. The guard fires on any truthy value other than `"Disabled"`
  or `"false"`, so an overlay that pins one of these keys *off* still renders. All six
  default off, so on any install that left them there the `routing-serving-certs`
  `Certificate` was never reconciled. The now-dead `gateway.config.certmanager` values
  key is removed.

  This also removes the `matchConditions` bootstrap exemption from both fail-closed
  knative webhooks in `webhookconfigurations.yaml`. It existed solely to let the
  `routing-serving-certs` `Certificate` be admitted in the same release that creates the
  webhook's backend; with that Certificate gone it matches nothing.

- **`kubernetes.podspec-dryrun` is set to `"disabled"` in `gateway.config.features`.**
  Knative's dry-run validation submits a real `Pod` create (`DryRun: All`) into the
  user's namespace, which needs cluster-wide `pods: create` — a privilege-escalation
  primitive, since it lets the holder schedule a pod under any ServiceAccount. The
  feature is opt-in per object via the `features.knative.dev/podspec-dryrun` annotation
  and nothing here uses it. **This does not change what is granted** — the new
  declarations never asked for `pods: create`; it makes the annotation inert so a future
  RBAC gap cannot surface as a confusing admission failure.

- **Out-of-chart consumers of the duck-type roles lose them.**
  `knative-serving-addressable-resolver` and `knative-serving-podspecable-binding` were
  contribution roles for *other* Knative components; nothing in this chart bound either
  to a surviving subject, so no union workload is affected. **If something else in your
  cluster — Knative Eventing is the usual case — relied on serving providing addressable
  or podspecable resolution, it must now supply its own.** Likewise, the
  `-namespaced-admin`/`-edit`/`-view` roles no longer aggregate Knative Serving objects
  into the built-in `admin`/`edit`/`view` roles; grant `serving.knative.dev` access
  explicitly if your users need it.

**Evidence base.** All of the above is verified against the committed rendered manifests
— `tests/generated/dataplane.aws.zero-trust.yaml` (default posture),
`dataplane.zero-trust-full-priv.yaml` (`low_privilege: false`),
`dataplane.zero-trust-per-component-sa.yaml` (split identities) and
`dataplane.zero-trust-full-priv-per-component-sa.yaml` (both at once, the only render in
which no pooled slot masks a missing per-component grant) — and by review of the
consuming code paths. **No part of it has been verified against a running cluster.**

### Migration / action required

- **`ingress-nginx` now watches only the release namespace, and an Ingress outside it stops
  being reconciled — with no error and no warning.** The controller simply does not see it.
  Both Ingresses this chart creates are release-namespace-pinned, so a default install is
  unaffected; if you serve an Ingress from another namespace through this controller, set
  both `ingress-nginx.rbac.scope: false` and `ingress-nginx.controller.scope.enabled: false`
  before upgrading. The two keys must always move together: the subchart already errors on
  `rbac.scope` without `controller.scope.enabled`, and the chart now errors on the reverse,
  which was the silent one — a controller confined by `--watch-namespace` while still
  holding the full cluster-wide grant.

- **One dataplane per cluster, if you were not already.** prometheus's `ClusterRole` and
  `ClusterRoleBinding` are named `union-operator-prometheus`, a fixed string with no
  namespace in it. Installing a second dataplane release into another namespace of the same
  cluster now fails on Helm ownership — loudly, at install, rather than by one release
  quietly taking over the other's binding. If you need two, override
  `prometheus.server.clusterRoleNameOverride` per install.

- **Removed values keys.** `prometheus.kube-state-metrics.metricRelabelings` and
  `dcgm-exporter.namespace`. Neither had a consumer; setting them changed nothing, and they
  are now ignored rather than silently ignored. If an overlay in your environment sets
  `dcgm-exporter.namespace` to scrape a dcgm-exporter outside the release namespace, that
  job no longer matches — it now discovers in the release namespace only. Two more go with
  the app-serving work: `gateway.components.autoscaler-hpa` (the workload is removed) and
  `gateway.config.certmanager` (the ConfigMap that read it is removed). Both are inert if
  an overlay still sets them; drop them.

- **App serving: three things to check before upgrading, if `zero_trust.enabled: true`.**
  Full detail in "App-serving (Knative) RBAC" above.
  1. **ServiceAccount rename.** The knative workloads move from `controller` / `activator`
     / `net-kourier` to `union-system` at the chart default. No action unless you bound
     external policy (e.g. a cloud IAM trust) to the old ServiceAccount names.
  2. **Enabling a `gateway.config.network` TLS key now fails the render.** If your
     overlay *enables* `external-domain-tls`, `cluster-local-domain-tls`,
     `system-internal-tls`, `namespace-wildcard-cert-selector`, `auto-tls` or
     `internal-encryption`, remove it — Knative certificate provisioning is not shipped
     and those settings were inert. An overlay that pins one of them to `"Disabled"` or
     `"false"` still renders; only a truthy value errors.
  3. **Out-of-chart Knative consumers.** If anything else in the cluster relied on this
     chart providing `knative-serving-addressable-resolver` / `-podspecable-binding`, or
     on Knative Serving objects reaching users through the built-in `admin`/`edit`/`view`
     roles, it must now supply those itself.

- **Metrics that start flowing.** `kube_*` from kube-state-metrics and `container_*` from
  cAdvisor have not been collected on a selfhosted dataplane. They will be after this
  upgrade, so expect the dataplane's remote_write volume to rise to what the dashboards
  reading them always assumed. Nine cluster-wide scrape jobs go away in the same release,
  which cuts the other way.

- **KNOWN ISSUE — connector-runtime apps report `ACTIVE` but their connector endpoint is
  never registered, at `low_privilege: false`.** The operator reads the connector
  `ConfigMap` — always a release-namespace object — through its controller-runtime
  manager's **cache-backed** client. That cache is unscoped at full privilege (no
  `limit-namespace`) and the client disables caching for nothing, so a read of one object
  in one namespace lazily starts a **cluster-wide ConfigMap informer**. Without
  cluster-wide `configmaps` `list`/`watch` the informer never syncs and the read fails.

  This is not confined to create and delete: the app reconciler performs the same read on
  the steady-state reconcile and returns the error, so the reconcile requeues and fails
  again, indefinitely. **Note the order, because it determines what you see.** The
  reconciler marks the app `ACTIVE`/`RUNNING` and writes that through to the control plane
  *before* it touches the connector `ConfigMap`. So the app does reach `ACTIVE` and stays
  there: **what you get is an app that looks healthy while its connector endpoint is
  absent from the ConfigMap and connector traffic does not route**, with an endless failing
  reconcile behind it. There is no `Forbidden` on the app object, no chart-time warning and
  no failed Helm release. If you are debugging routing for a connector app that the UI
  reports as running, this is the first thing to rule out.

  **This chart deliberately does not grant cluster-wide `configmaps` to work around it.**
  Doing so would hand union's ServiceAccount the contents of every ConfigMap on the
  cluster in order to satisfy one release-namespace read; that is a much worse trade than
  the bug. The fix belongs in the operator binary — scope the ConfigMap cache with
  `ByObject`, or use `mgr.GetAPIReader()` for this read — and there is no chart-side
  workaround that costs less than it buys.

  **What to do:** if you use connector-runtime apps, do not move to `low_privilege: false`
  until the operator image carries the fix. Deployments not using connector apps are
  unaffected, and `low_privilege: true` is unaffected in every case (the cache is scoped to
  the release namespace there, so the read is a namespaced one the `work-ns` Role covers).

- **New: `endpoints` `get`/`list`/`watch` in the release-namespace `union-comp-ns-read`
  Role, for `executor` and `leaseworker`.** Both register the `k8s:///` gRPC resolver
  unconditionally, and the chart's default connector endpoint
  (`k8s:///flyteconnector.<release-namespace>:8000`, with `connector-service` among the
  enabled plugins) makes them watch that `Service`'s `Endpoints`. The resolver retries with
  a **zero** backoff period, so a `Forbidden` is a hot loop against the API server plus
  connector tasks that never resolve. This is a namespaced `Role` in the release namespace,
  not a cluster grant. It is emitted in **both** privilege modes — under
  `low_privilege: true` it is redundant, because `union-work-ns` binds in the release
  namespace there and already conveys it, so **effective permissions in that mode are
  unchanged**; it is declared unconditionally so the component's stated needs match what it
  actually does. This is the only RBAC line that moves in a `low_privilege: true` render.

- **Behavior-preserving where a deployment already sets the value.** The removed overlay keys now come from base `values.yaml` defaults. If you relied on an overlay-set value that differs from the new base default, set it in your environment values instead. The one cross-cloud behavior change is catalog-cache `use-admin-auth`, which is now consistently enabled (previously `false` in the GCP overlay).
- **fluentbit `ServiceAccount` renamed** to `union-system` (from `fluentbit-system`). No action unless you bound external policy (e.g. a cloud IAM trust) to the old ServiceAccount name.
- **BREAKING for `namespaces.enabled: false` + `low_privilege: false` — this mode becomes a genuine multi-namespace deployment.** If you were running that combination and relying on it behaving as single-namespace, it will not any more: task pods are no longer pinned to the release namespace (propeller returns to `limit-namespace: all`, and `namespace_mapping` falls back to its `{{ project }}-{{ domain }}` default unless you set `namespace_mapping.template`). ServiceAccounts are unaffected: `commonServiceAccount.enabled` defaults to `true`, so components keep sharing `union-system` in this mode as before. **If you actually want single-namespace behavior, set `low_privilege: true`** — that is now the flag that means it, and `namespaces.enabled: false` on its own never did.
- **`clusterresourcesync.enabled` defaults to `false` — a `low_privilege: false` data plane must now enable it (or pre-create namespaces).** It was previously suppressed entirely in this mode by the `singleNamespace` gate, so leaving it off looked harmless. Now that the mode is genuinely multi-namespace, something has to create the per-project/per-domain namespaces and their RBAC as projects are registered. Either set `clusterresourcesync.enabled: true`, or pre-create every namespace your `namespace_mapping.template` can produce by some other means and enumerate them in `namespaces.static` with `namespaces.enabled: true`. Task pods land in `Forbidden`/`namespace not found` otherwise.

  **If you choose the static route, understand what it costs.** In that posture `clusterresourcesync` holds no cluster-wide grant, so it can only act in the namespaces listed in `namespaces.static`. A project registered after install lands in a namespace that is not on the list, and the component cannot provision it: its `b_default_service_account` and `c_project_resource_quota` templates return `Forbidden` on every sync cycle, indefinitely, with a render and an apply that both look clean. Concretely: **if `namespace_mapping.template` can produce namespace names that are not in `namespaces.static`, those projects will not work.** Nothing in the chart detects this. Use the static posture only when work namespaces really are provisioned ahead of time and adding a project is already a deploy step.
- **BREAKING: RBAC scope in that mode is narrowed — the old cluster-wide `ClusterRoleBinding`s are gone.** Helm removes them as part of the upgrade, so union workloads lose cluster-wide *write* reach the moment the release is applied and regain per-namespace reach as `clusterresourcesync` reconciles each project on its sync interval. What is deliberately kept is a read-only slice: the `union-<component>-work-ns-cluster-read` `ClusterRoleBinding`s, `list`/`watch` only, without which the components' cluster-wide caches cannot sync at all (see "Cluster-scoped reads at `low_privilege: false`" above). Existing work namespaces converge without operator action, but **there is a window** between the upgrade and the next sync in which tasks in namespaces not yet reconciled see `Forbidden`. At the default `refreshInterval: 5m` that window is minutes, not hours. Schedule the upgrade accordingly, and confirm afterwards with `kubectl get clusterrolebindings | grep union-` that only the expected cluster-scoped ones survive. **Do not delete anything on this list** — all of it is current:

  | Surviving `ClusterRoleBinding` | Why it is there |
  |---|---|
  | `union-<component>-cluster-read` / `-cluster-write` | grants that are cluster-scoped by necessity; among union's non-app-serving components only `clusterresourcesync`, the pod webhook and `nodeobserver` have any |
  | `union-<component>-work-ns-cluster-read` | **read-only** (`list`, `watch`) cache reads the API server authorizes as cluster-scope checks because the caller passes an empty namespace. One per enabled declarer — `executor`, `leaseworker`, `operator`, `proxy`, `webhook`, plus `flytepropeller` when enabled. See "Cluster-scoped reads at `low_privilege: false`" above for exactly what each holds. |
  | `union-clustersync-auth-delegator` | **load-bearing** — binds `clusterresourcesync` to the built-in `system:auth-delegator` `ClusterRole` for apiserver auth delegation. Deleting it breaks the component. Note the object name does not match its `roleRef`. |
  | `union-knative-<component>-cluster-read` / `union-knative-webhook-cluster-write` | app-serving informer reads and the webhook's two `resourceNames`-scoped writes; only in zero-trust mode with `apps.enabled`. See "App-serving (Knative) RBAC" above |
  | `union-operator-prometheus`, `<release-name>-kube-state-metrics` | third-party observability reads, from the subcharts — see "Third-party subchart RBAC" above |

  `<release-name>-fluentbit` is **not** on that list any more: this release sets
  `fluentbit.rbac.create: false`, so the subchart's `namespaces`/`pods` `ClusterRole`
  and `ClusterRoleBinding` are removed. Helm deletes them on upgrade; nothing needs
  them.

  There is no manual cleanup beyond confirming the old per-component bindings are gone.
- **BREAKING: if your overlay sets `clusterresourcesync.clusterRoleRules`, it will fail the render until you fix it.** The chart's previous default for this key was:

  ```yaml
  clusterresourcesync:
    clusterRoleRules:
      - apiGroups: ["", rbac.authorization.k8s.io]
        resources: [clusterrolebindings, configmaps, limitranges, namespaces,
                    podtemplates, pods, resourcequotas, rolebindings, roles,
                    secrets, serviceaccounts, services]
        verbs: ['*']
  ```

  An overlay that copied or extended that list now errors at template time:

  ```
  RBAC slot "cluster-write" names verb "*", which is not in the allowlist
  [get list watch create update patch delete deletecollection]. Wildcards, escalate,
  impersonate and bind are never permitted on a declared rule; bind is emitter-authored only.
  ```

  **This is a loud failure, which is the point** — the alternative was a silent narrowing
  discovered at the next sync cycle.

  **What to do, in order:**

  1. **Delete the key entirely and try that first.** The grants `clusterresourcesync`
     needs for the chart's own `a_namespace` / `b_default_service_account` /
     `c_project_resource_quota` templates — and for the `union-work-ns` RoleBinding it
     creates — are now derived and emitted without this key. For a stock install, empty
     is correct.
  2. **If your overlay adds its own `clusterresourcesync.templates` or
     `additionalTemplates` entries, check what resource types they create.** Eight of the
     twelve resources in the old default were over-grants that no default template ever
     used, and their absence is intended: `clusterrolebindings`, `roles`, `limitranges`,
     `services`, `secrets`, `configmaps`, `podtemplates`, `pods`. But an overlay whose own
     templates create objects of those types *was* authorized by the old default and is
     not now. **The four most likely to need re-adding are `limitranges`, `services`,
     `roles` and `clusterrolebindings`** — a per-project `LimitRange` and a core `Service`
     are the common cases.
  3. **Re-add only what you need, with explicit verbs.** For example:

     ```yaml
     clusterresourcesync:
       clusterRoleRules:
         - apiGroups: [""]
           resources: [limitranges]
           verbs: [get, create, patch]
     ```

  **Why `*` is rejected rather than accepted-and-warned:** on `roles` a verb wildcard
  conveys `escalate`, which switches off RBAC's own escalation-prevention check, and on
  `serviceaccounts` it conveys `impersonate`. Both were confirmed against a live API
  server, not inferred from the documentation. A wildcard is also uncheckable — a closed
  verb set can be reviewed in a diff, a wildcard cannot.
- **`namespaces.enabled` must be a YAML boolean.** It is read for Go-template truthiness, so `"false"` means **true**: the chart silently creates every namespace in `namespaces.static`, binds `union-work-ns` into them, and switches the deployment from the runtime posture to the static one — while the values file reads `false`. That switch also strips `clusterresourcesync` of its cluster-wide grant, so projects outside `namespaces.static` stop being provisioned. **If your overlay stringifies scalars (a `templatefile`/heredoc generator will, `yamlencode` will not), check this key before upgrading.** Use `--set`, not `--set-string`, if you set it on the command line.
- **Quoted booleans are a silent hazard on every boolean key, and the chart does not reject them.** Go's template engine treats any non-empty string as true, so `"false"` means **true**. The consequences differ by key: `namespaces.enabled: "false"` creates every namespace in `namespaces.static`, binds `union-work-ns` into them and switches the deployment to the static posture, while the values file reads `false`. `commonServiceAccount.enabled: "false"` collapses per-component identities onto the shared ServiceAccount, so each component holds the union of the others' rules. `config.operator.secretsWatcher.enabled: "false"` adds cluster-wide `update`/`patch` on Deployments. `low_privilege: "false"` fails safe, landing on the more restrictive branch. **If your values are generated, confirm the generator emits real booleans** — a `templatefile`/heredoc pipeline stringifies scalars, `yamlencode` does not. The rendered manifests for every fixture are committed under `tests/generated/`, which is where a wrong reading becomes visible.
- **Regenerate before adopting if your env still sets the retired CP-host globals.** An environment whose generated `values.yaml` still contains `global.CONTROLPLANE_GRPC_ENDPOINT` / `global.QUEUE_GRPC_ENDPOINT`, or a task-pod `default-env-vars` `_U_EP_OVERRIDE: "{{ include \`dataplane.cp.queueEndpoint\` . }}"`, must be regenerated (terraform apply) before moving to this chart — the `queueEndpoint` helper is removed, so the stale `include` fails to render. The retired globals are inert if set; drop them. Authless deployments move to `config.union.auth`/`config.union.connection` per `examples/values.authless.yaml`.

## 2026.7.2

Bumps `version` + `appVersion` to `2026.7.2`. `appVersion` moves from `2026.7.0` to
`2026.7.2`, so this release points at new data-plane (operator / executor / propeller /
dataproxy) images (notes below are the diff against the last stable release, `2026.7.1`,
whose `appVersion` was still `2026.7.0`).

### Configuration changes (helm-charts)

- **AWS storage overlay migrated to the stow backend** ([#493](https://github.com/unionai/helm-charts/pull/493)) — **fixes an executor crashloop**. The `provider: aws` branch of `_storage.tpl` emitted the legacy `type: s3` native connection block. flytestdlib's multi-scheme DataStore refactor ([flyteorg/flyte#7555](https://github.com/flyteorg/flyte/pull/7555)) routes every storage `Type` through stow and dropped the `type: s3` shorthand, so a `type: s3` config with no `stow.kind` panics `unsupported stow.kind []` at executor startup. AWS was the last provider not on stow (`gcs`/`azure`/`compat` already were). Now emits `type: stow` + `stow.kind: s3` driven by `authType` (IRSA and `accesskey` both render correctly). **AWS data planes should adopt this chart in lockstep with the `2026.7.2` executor image.**
- **Corrected Azure/GCP overlay defaults** ([#490](https://github.com/unionai/helm-charts/pull/490)):
  - *Namespace mapping (Azure + GCP).* GKE Workload Identity and Azure federated credentials have no wildcard subject support, so task namespaces must be a bounded set. The overlays pin `namespace_mapping.template` to `{{ domain }}`. On Azure this was previously nested under a `namespace_config` key the propeller ConfigMap never reads, so it was silently ignored and Azure fell through to the unbounded `{{project}}-{{domain}}` default. Moved to the correct top-level `namespace_mapping` key, gated on `not singleNamespace`.
  - *Azure operator secret backend.* The Azure overlay routed the operator's secret manager to Key Vault, but the flyte pod webhook reads the embedded K8s secret. Azure now defaults to the embedded K8s secret manager, matching AWS/GCP.
- **Single-namespace mapping pinned to the release namespace** ([#496](https://github.com/unionai/helm-charts/pull/496)) — **fixes task pods forbidden in single-namespace mode.** Under `low_privilege` / `namespaces.enabled: false` the `union-system` ServiceAccount has namespace-scoped RBAC, so task pods must land in the release namespace. The `nodeexecutor` ConfigMap emitted `namespace_mapping` twice when both `low_privilege` and a `namespace_mapping.template` were set — YAML last-key-wins made `{{ domain }}` win, so executor-routed task pods were created in the domain namespace and failed `pods is forbidden … in the namespace <domain>` (the operator had the same class of bug). A shared `dataplane.namespaceTemplate` helper is now the single source of truth for executor, leaseworker, and operator; under singleNamespace the executor overwrites `namespace_mapping` so the RBAC constraint always wins. Also removes the unused `config.namespace_config` / `config.namespace_mapping` keys, consolidating onto the canonical top-level `namespace_mapping`.
- **Eager API key minted per cluster** ([#486](https://github.com/unionai/helm-charts/pull/486)) — the dataplane now includes its cluster name when minting the eager API key, the chart half of per-data-plane operator + eager OAuth clients. Pairs with the control-plane `apiKeyOverrides` list ([controlplane #491](https://github.com/unionai/helm-charts/pull/491)) and requires the `2026.7.2` images.

### Platform (data-plane images — `appVersion 2026.7.2`)

The `appVersion` bump carries the data-plane images the chart changes above depend on:

- **Stow storage backend.** The executor routes all object storage through the stow backend ([flyteorg/flyte#7555](https://github.com/flyteorg/flyte/pull/7555)); a `type: s3` config with no `stow.kind` panics `unsupported stow.kind []` at startup, which is why the AWS overlay now emits `type: stow` + `stow.kind: s3` ([#493](https://github.com/unionai/helm-charts/pull/493)). Bump chart + image together.
- **Per-cluster eager API key.** The operator mints the eager API key using the data plane's cluster name ([#486](https://github.com/unionai/helm-charts/pull/486)), matching the control-plane per-cluster `apiKeyOverrides` entries.

Otherwise the `2026.7.2` tag is a routine data-plane image roll (bug fixes and improvements); nothing else in this chart release depends on it.

### Migration / action required

- **AWS data planes: adopt in lockstep with the executor image** ([#493](https://github.com/unionai/helm-charts/pull/493)). Once the executor rolls to a `2026.7.2` image (post-flyte#7555), an older chart still emitting `type: s3` crashloops the executor. Bump chart + image together. No action for GCP/Azure/OCI.
- **Per-cluster eager API key** ([#486](https://github.com/unionai/helm-charts/pull/486)) is coupled to the control-plane `apiKeyOverrides` list shape ([#491](https://github.com/unionai/helm-charts/pull/491)) and the `2026.7.2` images — bump control plane and data plane together.
- **Azure namespace mapping** ([#490](https://github.com/unionai/helm-charts/pull/490)): if you previously worked around the ignored `namespace_config` key with a manual override, drop it — the overlay now sets `namespace_mapping` correctly under multi-namespace (`low_privilege=false`) mode.
- **Namespace-mapping key consolidation** ([#496](https://github.com/unionai/helm-charts/pull/496)): the removed `config.namespace_config` / `config.namespace_mapping` keys were never generated by Terraform (only test fixtures used them); if you set them by hand, move to the top-level `namespace_mapping`. Behavior-preserving for multi-namespace deployments; single-namespace deployments now correctly place task pods in the release namespace.

## 2026.7.1

Chart-only patch release on top of `2026.7.0`; `appVersion` stayed `2026.7.0`. Highlights: zero-trust mode GA for BYOC data planes with a ready-to-use `examples/values.zero-trust.yaml` overlay; single canonical `operator.enableTunnelService` toggle; consolidated control-plane host resolution (fails fast if unset); chart-managed PriorityClasses for leaseworker/flytepropeller. See [PR #483](https://github.com/unionai/helm-charts/pull/483).

## 2026.7.0

First stable `2026.7.0`; `version` + `appVersion` bumped to `2026.7.0`. Highlights: dataplane self-registration — each data plane reports a bare `host` + TLS posture in `Status.connection_config` on every heartbeat so the control plane can route to it directly (opt-in via `updateStatus.connectionConfig.enabled`); billing defaults to v2 usage-based collection. See [PR #472](https://github.com/unionai/helm-charts/pull/472).

## 2026.6.9

### Changes

- Zero trust metrics push (#447) (5e59a4d)
- Selfmanaged controlplane: apiKeyOverrides, dataproxy connection host, operator eager-key toggle (#455) (8bd680d)

## 2026.6.7

### Changes

- Release/2026.6.7 (#451) (d472cd8)
- fix(dataplane): avoid emitting bare `{}` for empty custom storage config (#450) (bece749)
- Enable custom storage provider to include credentials from secret (#449) (eab4240)
- feat(dataplane): add opt-in FUSE device-plugin DaemonSet (#443) (1ca2c1a)
- feat(dataplane/serving): enable knative containerspec-addcapabilities (#448) (bcffc59)
- Fix/aks fluentbit (#442) (a1c3054)
- FAB-395: ci: add dataplane integration test on k3d with RustFS (#429) (82eca90)

## 2026.6.6

> **No chart-template or values changes.** This release advances the bundled `unionoperator` image tag and otherwise carries only the standard chart label / `helm.sh/chart` bumps.

### Highlights

- **Bundled `unionoperator` image tag advances `2026.6.3 → 2026.6.6`** (chart `appVersion` follows). Server-side, the operator gains support for offloaded trigger inputs; nothing to configure on the chart side.
- **Releases `2026.6.4` and `2026.6.5` were skipped** in the publish sequence — going straight from `2026.6.3` to `2026.6.6` is intentional.

### Helm chart changes (since `dataplane-2026.6.3`)

- Chart `version` + `appVersion` bumped to `2026.6.6`. No template, helper, or values changes.
- Snapshot fixtures regenerated. The only deltas are the `helm.sh/chart` / `app.kubernetes.io/version` labels and the `unionoperator` image tag.

### Image changes (appVersion `2026.6.3` → `2026.6.6`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.3` → `:2026.6.6` across every appVersion-tied dataplane workload (leaseworker, executor, operator-proxy, build-image, etc.).

### Migration notes

No migrations required. Routine `helm upgrade` from `dataplane-2026.6.3` carries no values changes.

## 2026.6.3

### Highlights

- **Knative serving pre-delete hook removed (potentially breaking on un-migrated installs).** `templates/serving/pre-delete-hook.yaml` is deleted — its orderly-uninstall responsibility is now owned by the `knative-migration` chart. Customers who already adopted `knative-migration` see no change; customers still on the bundled hook should adopt `knative-migration` before `helm uninstall` to avoid leaving Knative serving objects behind. See **Migration notes**.
- **Two unused leaseworker config values removed.** Dead values dropped from `charts/dataplane/values.yaml`; matching plumbing on the controlplane side ships in the `controlplane-2026.6.3` Actions/Leasor work.
- **Bundled `unionoperator` image tag advances `2026.6.2 → 2026.6.3`** (chart `appVersion` follows). Standard monthly release-train bump.

### Helm chart changes (since `dataplane-2026.6.2`)

- Chart `version` + `appVersion` bumped to `2026.6.3`.
- Deleted `templates/serving/pre-delete-hook.yaml` (~60 lines); responsibility moves to the `knative-migration` chart.
- Snapshot fixtures regenerated (~63 lines removed per dataplane snapshot — the bytes of the deleted hook resource).
- `charts/dataplane/values.yaml`: two unused leaseworker config values removed; 4 small net additions for the new run-service options threaded through from controlplane (no default behaviour change on the dataplane side).

### Image changes (appVersion `2026.6.2` → `2026.6.3`)

- `public.ecr.aws/p0i0a9q8/unionoperator:2026.6.2` → `:2026.6.3` across every appVersion-tied dataplane workload (leaseworker, executor, operator-proxy, build-image, etc.).

### Migration notes

- **Adopt `knative-migration` before uninstall.** With the pre-delete hook gone, `helm uninstall <dataplane-release>` no longer cleans up Knative serving objects on its own. If you've been relying on the bundled hook, switch to the `knative-migration` chart (same repo) for orderly Knative lifecycle before the next uninstall.
- **No action required for ongoing upgrades.** Fresh installs and routine `helm upgrade`s are unaffected.

## 2026.6.2

### Highlights

- **DP→CP TLS defaults flipped to TLS-on across FIVE consumer paths (potentially breaking for self-signed envs).** Pre-6.2, the `values.aws.yaml` / `values.gcp.yaml` overlays each carried duplicate connection blocks that re-declared the consumer with TLS-skip enabled. As of 6.2 those overlay blocks are gone — every consumer falls through to the base `values.yaml`, which defaults to TLS-on. The five paths, with their **exact** bool-key spellings (three different schemas — they are NOT interchangeable):

  | Path | Bool key(s) — exact spelling | Pre-6.2 effective | Post-6.2 default |
  |---|---|---|---|
  | `clusterresourcesync.config.union.connection` | `insecureSkipVerify` *(camelCase)* | `true` *(overlay)* | `false` *(base)* |
  | `config.admin.admin` | `insecure`, `insecureSkipVerify` *(camelCase)* | `insecure: true` *(overlay)* | `insecure: false`, `insecureSkipVerify: false` |
  | `config.catalog.catalog-cache` | `insecure`, **`insecure-skip-verify`** *(hyphenated — different schema!)* | `insecure: true` *(overlay)* | `insecure: false`, `insecure-skip-verify: false` |
  | `config.union.connection` | `insecureSkipVerify` *(camelCase)* | `true` *(overlay)* | `false` *(base)* |
  | `config.k8s.plugins.k8s.default-env-vars` (task pods) | env-var pair `_U_INSECURE`, `_U_INSECURE_SKIP_VERIFY` | `_U_INSECURE: true` *(overlay)* | `_U_INSECURE: false` *(overlay rewritten)* |

  Default host expression for all five now resolves through the new `dataplane.cp.endpoint` / `dataplane.cp.queueEndpoint` helpers to `dns:///<CONTROLPLANE_HOST>:443` (TLS-terminating nginx port). See **Migration notes** for the exact opt-back snippet for self-signed CP certs.

- **Storage credentials from a Kubernetes Secret.** New `storage.credentialsSecretRef.name` value lets you mount AWS-S3-compatible access/secret keys from a pre-existing Secret instead of putting them in plaintext values. No-op if you keep credentials inline.

- **Opt-in Zero Trust overlay.** A new `values.zero-trust.yaml` overlay enables Zero Trust networking for the dataplane in one layer.

- **`knative-operator` subchart now sourced from the public Helm repo** (`https://unionai.github.io/helm-charts`, pinned to `2026.6.0`). The temporary `file://../knative-operator` pin is removed, and Knative CRDs are bundled directly under `charts/dataplane/crds/` so a default `helm install` (no `--skip-crds`) installs them automatically — fixes the prior `KnativeServing` "resource mapping not found" failure on fresh installs.

### Helm chart changes (since `dataplane-2026.6.1`)

- Chart `version` + `appVersion` bumped to `2026.6.2`.
- `dependencies.knative-operator.repository` switched from `file://../knative-operator` to `https://unionai.github.io/helm-charts`; pinned to `2026.6.0`.
- 13 Knative CRDs bundled under `charts/dataplane/crds/` (Helm 3 `crds/` auto-install path). Byte-identical to the vendored mirror at `crds/knative-operator/` used by the `--skip-crds` server-side-apply path.
- New `templates/_connection.tpl` helper (`dataplane.cp.host`, `dataplane.cp.endpoint`, `dataplane.cp.queueEndpoint`) — collapses the previously-duplicated `dns:///{{ tpl .Values.host . }}` host expression into a single helper and coalesces a new `global.CONTROLPLANE_HOST` with the legacy `Values.host` for backwards compatibility. The bool TLS fields are NOT folded into a helper — bool YAML coercion through helm template strings is fragile across the three different Go config schemas (see Highlights), so each consumer writes the bool literal inline.
- Base `values.yaml` — explicit TLS-on at each consumer:
    - `clusterresourcesync.config.union.connection.insecureSkipVerify: false` *(was commented out)*
    - `config.admin.admin.insecure: false`, `config.admin.admin.insecureSkipVerify: false`
    - `config.catalog.catalog-cache.insecure: false`, `config.catalog.catalog-cache.insecure-skip-verify: false` *(hyphenated)*
    - `config.union.connection.insecureSkipVerify: false` *(was commented out)*
- `values.aws.yaml`, `values.gcp.yaml`:
    - Dropped redundant `config.admin.admin.{endpoint,insecure}` block.
    - Dropped redundant `config.catalog.catalog-cache.{type,cache-endpoint,endpoint,insecure}` block.
    - Dropped redundant `config.union.connection.{host,insecureSkipVerify}` block.
    - Dropped redundant `clusterresourcesync.config.union.connection.{host,insecureSkipVerify}` block.
    - Cloud overlays now carry only the cloud-specific bits (auth client id, catalog `use-admin-auth: false`, task-pod env vars).
    - Task-pod env vars rewritten: `_U_EP_OVERRIDE` now uses the `dataplane.cp.queueEndpoint` helper; `_U_INSECURE: false` (was `true`); `_U_INSECURE_SKIP_VERIFY: false` (unchanged).
- New `values.zero-trust.yaml` overlay for opt-in Zero Trust networking.
- New `storage.credentialsSecretRef.name` value; storage helpers wire it through to the operator and execution paths (build-image, reusable containers covered).
- Configurable webhook headless template revived (now that the matching cloud-side support has landed).
- Reverted the in-flight `proxy.smConfig.webhookHostTemplate` default from 6.1 (`#420` → `#421`).

### Images to vendor (delta vs `dataplane-2026.6.1`)

Two image-surface changes for vendoring customers:

**1. `knative-operator` subchart moved from a local bundled copy to the public Helm repo.**

| Was | Now |
|---|---|
| `repository: file://../knative-operator`, `version: 2026.4.6` | `repository: https://unionai.github.io/helm-charts`, `version: 2026.6.0` |

The operator image + its `kube-rbac-proxy` sidecar are now pulled per the upstream subchart's `values.yaml`. After upgrade, re-resolve the subchart's image set:

```bash
helm dependency update charts/dataplane
helm template charts/dataplane | grep -E '^\s+image:' | sort -u
```

**2. Six Knative-serving images are now pinned by digest directly in dataplane templates.**

Previously these were rendered by the operator at reconcile time off a `KnativeServing` CR — they were running in your cluster but not part of the chart's declared image surface. As of 6.2 they're baked into `templates/gateway/*.yaml` with explicit digests. Vendoring customers who scan the chart for image refs (rather than scraping live clusters) should add all six to the mirror set:

| Component | Image (digest-pinned) |
|---|---|
| activator | `gcr.io/knative-releases/knative.dev/serving/cmd/activator@sha256:24c19cbee078925b91cd2e85082b581d53b218b410c083b1005dc06dc549b1d3` |
| autoscaler | `gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler@sha256:5e9236452d89363957d4e7e249d57740a8fcd946aed23f8518d94962bf440250` |
| autoscaler-hpa | `gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler-hpa@sha256:64166849fc5fd9b03ab2c1ebca72e70b826cf30e731b1fa3cdf725cdd30d6210` |
| controller | `gcr.io/knative-releases/knative.dev/serving/cmd/controller@sha256:5fb22b052e6bc98a1a6bbb68c0282ddb50744702acee6d83110302bc990666e9` |
| webhook | `gcr.io/knative-releases/knative.dev/serving/cmd/webhook@sha256:0fb5a4245aa4737d443658754464cd0a076de959fe14623fb9e9d31318ccce24` |
| queue (sidecar — referenced in `configmap-deployment.yaml` and `misc.yaml`) | `gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:c61042001b1f21c5d06bdee9b42b5e4524e4370e09d4f46347226f06db29ba0f` |

Mirror by exact digest — the chart references them by digest, not tag, so a tag-only mirror is not sufficient.

The `unionoperator`, `envoy`, and other first-party templated images (`flytecopilot`, `kube-state-metrics`, sidecar helpers) are unchanged in this release apart from the `appVersion` retag to `:2026.6.2`.

### Migration notes

#### TLS-mode flip is the load-bearing change

If your dataplane connects to a control plane over a **publicly-trusted CA cert** (every Union-managed deployment, and any selfmanaged deployment behind ingress fronted by cert-manager / Let's Encrypt / a real CA), no action is needed — the new TLS-on defaults match what the connection actually needs.

If your control plane terminates with a **self-signed cert** (typical for self-hosted environments before the cert-manager / external-CA step), you need to opt back into TLS-skip at the env-overlay layer. Symptom of missing this:

```
rpc error: code = Unavailable desc = connection error: desc =
"error reading server preface: ... x509: certificate signed by unknown authority"
```

**Watch the three field-name dialects.** If you mass-find-and-replace one spelling across your values file, exactly one consumer will silently not honour it. Use the snippet below verbatim:

```yaml
# Opt back into TLS-skip on every DP→CP consumer.
# Use only with self-signed CP certs the dataplane pods cannot trust;
# leave at defaults (false) when CP is fronted by a publicly-trusted CA.

# 1. ClusterResourceSync → CP
clusterresourcesync:
  config:
    union:
      connection:
        insecureSkipVerify: true        # camelCase

# 2. Flyteadmin client
# 3. Catalog client (catalog-cache)
# 4. Union services client
config:
  admin:
    admin:
      # insecure: true                  # uncomment only if dropping TLS entirely (plaintext)
      insecureSkipVerify: true          # camelCase

  catalog:
    catalog-cache:
      # insecure: true                  # uncomment only if dropping TLS entirely
      insecure-skip-verify: true        # HYPHENATED — cacheservice schema, NOT camelCase

  union:
    connection:
      insecureSkipVerify: true          # camelCase

  # 5. Task-pod env vars (queue endpoint from inside user pods)
  k8s:
    plugins:
      k8s:
        default-env-vars:
          # _U_INSECURE drops TLS entirely; _U_INSECURE_SKIP_VERIFY keeps TLS but skips cert validation.
          # For a self-signed CP cert behind nginx:443 you want the second, not the first.
          - _U_INSECURE: false                # set true only if the queue endpoint is plaintext HTTP/h2c
          - _U_INSECURE_SKIP_VERIFY: true     # TLS on, cert validation off — matches the other 4 consumers
```

Two things worth being explicit about:

- **`insecure` vs `insecureSkipVerify` are different knobs.** `insecure: true` drops TLS entirely (plaintext gRPC/HTTP). `insecureSkipVerify: true` keeps TLS but accepts any presented cert. For a self-signed CP cert behind nginx-on-443 you want the latter — flipping `insecure: true` will produce `http2: server sent GOAWAY and closed the connection` against a TLS port.
- **Task pods speak a separate dialect** (`_U_INSECURE` / `_U_INSECURE_SKIP_VERIFY` env vars), because the SDK reads env, not the helm config schema. These two are still set in the cloud overlays — they did NOT move to base. Override at the env-overlay layer the same way the cloud overlays do.

Selfmanaged Terraform-driven envs pick this up automatically via the companion cloud-side change; hand-rolled overlays need to set the snippet above explicitly.

#### Knative install path

Fresh installs are now the default `helm install` (CRDs in `charts/dataplane/crds/`). The documented production path stays `helm install --skip-crds` + `kubectl apply --server-side -f crds/knative-operator/` (avoids the 256 KiB `last-applied-configuration` annotation overflow and is forward-compatible with Helm 4). No action required on upgrades — Helm's `crds/` directory is install-only.

#### Storage credentials

No migration required. Keep credentials inline as `storage.accessKey` / `storage.secretKey` if you prefer, or move them to a Secret and set `storage.credentialsSecretRef.name`.

#### Zero Trust

Opt-in. Include `values.zero-trust.yaml` in your overlay set if you want it.

## 2026.6.1

> Chart-only release: `appVersion` stays at `2026.6.0`. No image changes — see `dataplane-2026.6.0` for the image notes.

### Highlights

- **Per-cloud overlay consolidation (potentially breaking for external consumers).** The `values.{aws,gcp}.selfhosted-intracluster.yaml` overlays are **deleted**; their contents become the canonical `values.{aws,gcp}.yaml`. One canonical overlay per cloud now serves every topology — topology is decided by env-layer Service annotations and DNS, not by chart values. See **Migration notes** and `charts/MIGRATION.md`.
- **DP→CP endpoint variables collapsed into a single canonical `CONTROLPLANE_HOST`.** Existing env overlays that set the legacy names (`CONTROLPLANE_INTRA_CLUSTER_HOST`, `QUEUE_SERVICE_HOST`, `FLYTEADMIN_ENDPOINT`, `CACHESERVICE_ENDPOINT`) keep working unchanged via `default`-based fallback.
- **FlyteWorkflow CRD is now bundled in the chart's `crds/`** so `helm install` auto-applies it, while a byte-identical mirror at `crds/flyte-v1/` stays available for the server-side-apply / ArgoCD install path.

### Helm chart changes (since `dataplane-2026.6.0`)

- Chart `version` bumped to `2026.6.1`; `appVersion` unchanged (`2026.6.0`) — this is a chart-only release.
- Deleted `values.aws.selfhosted-intracluster.yaml` / `values.gcp.selfhosted-intracluster.yaml`; canonical `values.{aws,gcp}.yaml` now carry the (mode-agnostic) intracluster content. Pre-consolidation contents preserved at `examples/values.{aws,gcp}.legacy.yaml`; intracluster overrides at `examples/values.{aws,gcp}.intracluster.yaml`.
- Introduced `global.CONTROLPLANE_HOST`; the four legacy DP→CP endpoint vars fall through to it.
- FlyteWorkflow CRD bundled at `charts/dataplane/crds/crd-flyteworkflows.yaml` (Helm 3 `crds/` auto-install) and mirrored byte-for-byte to `crds/flyte-v1/` (CI-gated). The deprecated `charts/dataplane-crds/` path is unchanged.
- Fixed a permanent ArgoCD **OutOfSync** on the FlyteWorkflow CRD by dropping a trailing empty `properties:` key that Kubernetes strips server-side at admission.
- Added `metrics-manifest.yaml` + `make generate-metrics-manifest` to track metric/dashboard/rule changes in PR diffs (tooling only — no runtime change).

### Migration notes

**Read `charts/MIGRATION.md` for the full story.** Summary:

- **If you fetch `values.{cloud}.selfhosted-intracluster.yaml` over HTTP**: that filename now returns 404. Switch to canonical `values.{cloud}.yaml` and layer `examples/values.{cloud}.intracluster.yaml` on top for intra-cluster routing.
- **Legacy host variables still work** via `{{ default <canonical> <legacy> }}` fallback. Move to `CONTROLPLANE_HOST` when convenient.

**FlyteWorkflow CRD install path.** Two equally-supported options:

- **Recommended (selfhosted / intra-cluster):** `helm install … --skip-crds` and apply the CRD yourself — `kubectl apply --server-side -f crds/flyte-v1/` (or point ArgoCD at `crds/flyte-v1/`). Full lifecycle is owned by whoever runs the apply.
- **One-shot:** `helm install …` (no `--skip-crds`) installs the bundled CRD on first install. Note Helm's `crds/` directory is **install-only** — `helm upgrade` will never modify the CRD.

The OutOfSync fix is automatic; no action required beyond re-syncing once.

## 2026.6.0

### Highlights

- **Billing / usage collection now works in low-privilege mode.** A new `config.operator.cloudProvider` value lets you set the cluster's cloud provider explicitly (used for GPU accelerator labelling and usage attribution) instead of relying on node-label auto-detection, which is unavailable when the operator runs with reduced RBAC.

### Helm chart changes (since `dataplane-2026.5.9`)

- Chart version + `appVersion` bumped to `2026.6.0`.
- New `config.operator.cloudProvider` value (defaults to the top-level `provider`). Selects the GPU accelerator node label for usage attribution and tags billable usage. When empty and the operator is **not** in low-privilege mode, it still falls back to detecting the provider from node labels.

### Image changes (appVersion `2026.5.9` → `2026.6.0`)

- Operator `kube-rbac-proxy` sidecar now pulls the public `quay.io/brancz/kube-rbac-proxy` image. If you mirror images into a private registry, add this repository to your mirror set.

### Migration notes

No dataplane-specific migrations required for this release.

Low-privilege deployments pick up usage collection automatically. If your cluster's provider can't be inferred (e.g. you run with reduced RBAC), set `config.operator.cloudProvider` to `aws`, `gcp`, `azure`, `oci`, or `metal`.

_Pre-releases (2026.6.10-alpha.*) are omitted; 2026.6.10 shipped as 2026.7.0._
