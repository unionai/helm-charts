# dataplane — Release Notes

## 2026.8.5

Chart-only release: `version` moves `2026.8.4` → `2026.8.5`; `appVersion` stays
`2026.8.5`, so images are unchanged.

- `storage.credentialsSecretRef` gains an optional `namespace` field so the
  render-time secret `lookup` can read a fixed, pre-created namespace instead
  of the release namespace — unblocks Omnistrate installs where the release
  namespace is instance-derived and unknowable before the first install.
  Empty/absent `namespace` keeps the exact current behavior
  ([#567](https://github.com/unionai/helm-charts/pull/567)).
- Interruptible node routing: `values.gcp.yaml` now routes `interruptible`
  tasks to Spot nodes by default via the uniform `cloud.google.com/gke-spot`
  label (node selector only — GKE labels Spot nodes but does not taint them),
  matching the Azure default; AWS keeps commented guidance because its Spot
  label is provisioner-specific
  ([#561](https://github.com/unionai/helm-charts/pull/561)).
- Leaseworker / union-operator control-plane connection liveness hardened by
  default: `config.union.connection` sets `unaryRPCTimeout: 30s` and HTTP/2
  keep-alive (`readIdleTimeout: 30s` / `pingTimeout: 10s`), so an idle
  connection half-opened by a load balancer is detected and re-dialed instead
  of silently stalling heartbeats and lease dispatch
  ([#540](https://github.com/unionai/helm-charts/pull/540)).
- `artifact-trigger` added to the `enabled-plugins` list rendered into the
  leaseworker and propeller configmaps. Inventory-accuracy change — core
  plugins currently load unconditionally, and propeller ignores unknown names
  ([#511](https://github.com/unionai/helm-charts/pull/511)).

## 2026.8.4

`version` moves `2026.8.3` → `2026.8.4` and `appVersion` moves `2026.8.3` →
`2026.8.5`, picking up the new data-plane images, the RBAC rework described in
the sections below ([#554](https://github.com/unionai/helm-charts/pull/554),
[#555](https://github.com/unionai/helm-charts/pull/555)), and two smaller chart
changes ([#552](https://github.com/unionai/helm-charts/pull/552),
[#556](https://github.com/unionai/helm-charts/pull/556)); everything else ships
in the images.

Chart changes:

- Right-size default CPU/memory **requests** for data-plane services
  (`leaseworker`, BuildKit image-builder, operator, connector,
  cluster-resource-sync, node-observer, Kourier). **Limits are unchanged** —
  BuildKit keeps unlimited memory and `leaseworker` keeps its `16Gi` limit (its
  request drops `8Gi`→`512Mi`) — so only the idle reservation shrinks, improving
  packing so the autoscaler consolidates onto fewer nodes. Override
  `<service>.resources.requests.{cpu,memory}` to restore
  ([#552](https://github.com/unionai/helm-charts/pull/552)).
- Every data-plane pod now honors the chart-level **global scheduling** default
  (`.Values.scheduling.*`) — `flyteconnector` and all seven gateway components
  gained `tolerations`/`nodeSelector` fields so they can schedule onto a tainted
  pool. **Task-execution pods** inherit it too via the `task-template` PodTemplate
  (`taskPodTemplate.{nodeSelector,affinity,tolerations}`). Per-service
  `tolerations`/`nodeSelector` **inherit** from the global block (concat / merge,
  service wins); `affinity` overrides. Inert by default
  ([#556](https://github.com/unionai/helm-charts/pull/556)).
- **RBAC is narrowed across the board**, and the privilege/namespace axes are
  untangled. Several of these are breaking — see the sections below, ending with
  *Migration / action required*
  ([#554](https://github.com/unionai/helm-charts/pull/554),
  [#555](https://github.com/unionai/helm-charts/pull/555)).

Image changes (`2026.8.3` → `2026.8.5`):

- **Apps no longer freeze on "Deploying / Initializing" after an OOM kill or
  crash.** When a container terminates non-zero *after* its revision became
  ready, Knative's sticky `ContainerHealthy` condition leaves the revision
  `Ready=False, reason=ExitCode<N>` while the KService reports only a generic
  `RevisionMissing`, so the operator wrote a substate-less `PENDING` that the
  status updater's anti-churn guard then dropped — the app's status stuck on a
  stale condition with no path to recovery short of a redeploy. The reconciler
  now reads the Revision reason and classifies it: `ExitCode137` (and a literal
  `OOMKilled`) → `OOM_KILLED`, any other `ExitCode<N>` → `CRASH_LOOP`, each with
  a short summary such as `Container exited with code 137 (out of memory)`
  ([unionai/cloud#17871](https://github.com/unionai/cloud/pull/17871)).
- **Kourier stops watching every Secret in the cluster.** The bundled
  `net-kourier` build is bumped to pick up
  [unionai/net-kourier#13](https://github.com/unionai/net-kourier/pull/13),
  cutting the Serving ingress controller's apiserver watch load and cache
  footprint on clusters with many Secrets
  ([unionai/cloud#17870](https://github.com/unionai/cloud/pull/17870)).

### Privilege and namespace axes

- **`low_privilege` is now the chart's only privilege axis; `namespaces.enabled` no longer
  implies single-namespace mode.** The `singleNamespace` helper — which drives
  `limit-namespace` / `namespace_mapping` / `limitNamespace` injection, the single-namespace
  task PodTemplate, and the `clusterresourcesync` gate — was
  `or (not namespaces.enabled) low_privilege`. That folded a
  namespace *pre-seed* toggle into a *privilege* decision, and the two are not the same thing:
  `namespaces.enabled` only pre-seeds a fixed list of namespaces, while a full-privilege
  dataplane creates namespaces for newly registered projects dynamically via
  `clusterresourcesync`. `singleNamespace` is now exactly `low_privilege`, the one flag that
  really does mean "no namespaces are created by any route."

  **This fixes a silent misconfiguration in the default full-privilege install.**
  `namespaces.enabled` defaults to `false`, so `low_privilege: false` alone previously put the
  chart in single-namespace mode — and all three `clusterresourcesync` templates are gated
  `not singleNamespace`, so the very component that creates per-project namespaces was
  suppressed. A multi-namespace dataplane that left `namespaces.enabled` at its default had
  nothing creating namespaces for new projects at all.

  **Every `low_privilege: true` deployment is namespace-scoped exactly as before**, and
  pre-seeds nothing regardless of `namespaces.enabled`. Only the
  `namespaces.enabled: false` + `low_privilege: false` combination changes behaviour; see
  Migration.

- **`commonServiceAccount.enabled` is now honored in every privilege mode.** The
  `useCommonServiceAccount` helper previously returned true whenever `singleNamespace` was
  set, so an explicit `commonServiceAccount.enabled: false` was silently discarded in the
  chart's default mode. Identity sharing and privilege scope are independent concerns and are
  now keyed independently. **The default is unchanged (`true`), so any install that leaves the
  key alone is unaffected** — but an install that already sets it `false` while running in the
  old single-namespace mode had that setting ignored, and will now get what it asked for.
  Setting it `false` creates one ServiceAccount per component; each new name needs a matching
  workload-identity binding on the cloud side before those workloads can authenticate. The
  names are `operator-system`, `proxy-system`, `leaseworker`, `union-webhook-system`,
  `union-imagebuilder` (buildkit, enabled by default) and — under `zero_trust.enabled` —
  `dataproxy-system`. **`fluentbit` is the exception and needs a manual step:** its account
  name comes from the subchart key `fluentbit.serviceAccount.name`, which this chart pins to
  `union-system`, and that pin wins over the per-component fallback. Set it to a dedicated
  name yourself if you want fluentbit partitioned too; its `rbac.create` is false here, so
  the account carries no Kubernetes permissions either way.

  It does not change `Role` versus `ClusterRole` scope, but it does partition the existing
  grants across identities: the shared `union-system` account is the subject of every
  component's binding at once, where per-component accounts each hold only their own. A
  compromised workload can no longer exercise the other components' grants. That is a real
  reduction in each workload's effective permissions — plan the cloud-side bindings before
  flipping it, not after.

- **`namespaces.static` (new)** enumerates the work namespaces to pre-create when
  `namespaces.enabled: true`. It defaults to the six names `common/namespaces.yaml` previously
  hardcoded (`flytesnacks-{development,staging,production}` and
  `union-health-monitoring-{development,staging,production}`), so the rendered output is
  unchanged for anyone who has not set it. **This is not the full set a dataplane uses** —
  `clusterresourcesync` creates one namespace per project/domain at runtime and cannot know
  those names in advance.

  Leaving `namespaces.enabled: false` remains the supported path for externally-managed
  namespaces: when Terraform, a platform team or anything else owns the `Namespace` objects,
  Helm never touches them and there are no adoption annotations to negotiate.

- **`namespaces.labels` and `namespaces.annotations` (new)** set metadata on every Namespace
  the chart creates — Pod Security Standards levels, service-mesh injection, cost attribution,
  or a retention key for your deployment tool. They cover the `static` list only; namespaces
  `clusterresourcesync` creates at runtime are shaped by the `a_namespace` entry in
  `clusterresourcesync.templates`, as before.

- **`namespaces.annotations` defaults to `helm.sh/resource-policy: keep`, so `helm uninstall`
  no longer deletes the pre-seeded namespaces.** Uninstalling previously cascade-deleted each
  managed namespace and everything inside it: task pods, Secrets, PVCs, and objects
  `clusterresourcesync` created at runtime that this chart never knew about. That is the
  ordinary consequence of Helm owning a resource, but the resource is a whole namespace,
  which made it the largest blast radius in the chart and rarely what "uninstall the
  dataplane" was meant to mean. Leftover namespaces are one `kubectl delete` to recover; the
  reverse is not.

  **Helm is the only thing that honors that key.** A GitOps controller renders this chart and
  reconciles against its own bookkeeping, so it prunes a Namespace that leaves the desired
  manifest no matter what Helm annotations it carries — Argo CD does not map
  `helm.sh/resource-policy` to a sync option at all. If you deploy that way, add your
  controller's own retention key; they merge with the default:

  ```yaml
  namespaces:
    annotations:
      argocd.argoproj.io/sync-options: Prune=false,Delete=false
  ```

  Set `helm.sh/resource-policy: null` to drop the default entirely and let your tooling own
  the namespace lifecycle.

### Union RBAC is split by destination

Union's own grants are partitioned on *where* they apply rather than on which component asked
for them. In the usual `union` release namespace:

| Role | Kind | Bound by | Holds |
|---|---|---|---|
| `union-<component>-comp-ns-read`, `union-<component>-comp-ns-write` | `Role` | `RoleBinding` in the release namespace | what that component needs on Union's *own* objects. One Role per component: nothing is shared here |
| `union-work-ns` | `ClusterRole`, or `Role` under `low_privilege: true` | one `RoleBinding` per work namespace — **never** in the release namespace at `low_privilege: false` | what components need on user tasks, apps and builds |
| `union-<component>-work-ns-cluster-read` | `ClusterRole` | `ClusterRoleBinding` | reads the API server authorizes as cluster-scope checks, because the caller lists with an empty namespace. Read-only (enforced at render time); the chart's own rules here use `list`/`watch` alone, and none is emitted at all under `low_privilege: true` |

**Read-only on that row is enforced at render time, not by convention.** A slot whose name
ends in `-read` — `work-ns-cluster-read` included — admits `get`, `list` and `watch` and
rejects every write verb, and the chart refuses to render rather than emitting one. What
is enforced is the absence of writes; that today's `work-ns-cluster-read` rules stop at
`list` and `watch` is a property of the declarations, not of the check. A `get` in a read
slot is legitimate and one renders — see the Knative webhook's `resourceNames`-pinned
namespace read below.

**`union-work-ns` is the only role several components share.** The release-namespace roles
were shared too in earlier drafts of this model, which meant every component holding every
other component's release-namespace rules: the Knative activator registers a namespaced
Secret informer unconditionally, and that one rule gave the operator, leaseworker and the
other four app-serving binaries a read of every Secret in the release namespace. (Not the
proxy — it declares into neither `comp-ns` slot, so it was never a subject of that role.
Its own release-namespace Secret grant comes from `operator/serviceaccount-proxy-secret.yaml`
and is unaffected by any of this.)
They are now one Role per component, `union-<component>-comp-ns-read` and
`-comp-ns-write`. **Anything outside this chart that references `union-comp-ns-read` or
`union-comp-ns-write` by name — an audit policy, a `RoleBinding`, a Kyverno rule — stops
matching.** Nothing named `union-comp-ns-*` renders any more. The resource declarations are
redistributed unchanged; their verb sets are narrowed, as the next section describes — so
this is not a rename you can skim past.
`work-ns` stays shared, because the namespaces it is bound in are created at
runtime and one role there means one `RoleBinding` and one `bind` grant per namespace
instead of one per component.

**Every RBAC rule in the chart now declares its own `verbs`, and they are narrowed.**
Previously the three release-namespace and work-namespace slots had the emitter stamp a
fixed verb set onto every rule and refuse any rule that named its own, so no rule could
ask for less than the whole set. Each rule now names what its component calls, taken from
the verbs the role it replaced actually granted. What that removes, in the grants an
operator is most likely to be asked about:

| Grant | Was | Is |
|---|---|---|
| proxy, on everything it touches in a work namespace | full write set | `get`, `list`, `watch` — it is a reader and now says so |
| pod webhook, on `secrets`/`pods` in a work namespace | full write set | `get`, `list`, `watch`, `create`, `update`, `patch`; no `delete` |
| `knative-controller`, on `serviceaccounts`/`secrets` for image digest resolution | full write set | `get` |
| `net-kourier`, on `ingresses` | full write set | `get`, `list`, `watch`, `patch`, plus `update` on `ingresses/status` |
| `deletecollection`, anywhere | every rule in three slots | `flyteworkflows` and the Knative API groups only |
| `endpoints/restricted` | the surrounding rule's whole verb set | `create`, the one verb the admission plugin checks |

Note the pooled `work-ns` role is the union of its declarers' rules, so narrowing one
declarer there does not narrow what the others convey to it — the proxy is bound to a role
that still carries `leaseworker`'s resource wildcard. The release-namespace roles are the
ones where a narrowed declaration is the whole grant.

No operator-set value changes behavior, so this is not called out with a `BREAKING` banner
above — but it does break the *declaration contract* for anything defining its own
`dataplane.rbac.slots.<name>`: a downstream fork of this chart, or an overlay that adds a
component via that same mechanism. Every rule such a declaration contributes must now carry
a `verbs` key of its own; the chart refuses to render if one is missing, where it previously
inferred the verbs from the slot in three of the six cases.

**The split is the point.** `union-work-ns` is a `ClusterRole` only so its rules are written
once; a `RoleBinding` referencing a `ClusterRole` confines that role to the binding's own
namespace. Because it is never bound in the release namespace at `low_privilege: false`,
`union-work-ns` conveys no access at all to Union's own Deployments and Secrets: what it grants
in a work namespace stops at that namespace's edge. Under `low_privilege: true` the release
namespace *is* the work namespace, so `union-work-ns` is a plain `Role` bound there, as before.

That is a claim about `union-work-ns`, not about everything a given ServiceAccount can do. RBAC
unions every binding a subject holds, so a component's effective permissions are the sum of its
slot roles *and* any role outside the slot model. One such grant exists at stock values: with
`proxy.secretManager.enabled: true` and `type: K8s` (both defaults), the proxy holds `get`,
`list`, `create`, `update` and `delete` on Secrets in `proxy.secretsNamespace`, which defaults
to the release namespace. Set `proxy.secretManager.namespace` to keep Union-managed secrets out
of the release namespace. With `commonServiceAccount.enabled: true` (the default) every
component shares one identity, so each also holds every other component's roles — split the
identities before reasoning about any component's permissions individually.

The work-namespace role is **pooled**: one object holding the union of every declaring
component's rules, bound to every declaring ServiceAccount. Pooling there is by destination,
not by identity, so `commonServiceAccount.enabled: false` does not multiply the object count
in work namespaces — and does not narrow anything there either. Splitting the identities buys
one cloud IAM identity per component; in a work namespace, each still holds every other
declarer's rules. The release-namespace and cluster-scoped roles are per-component, so
splitting identities does separate those.

**Verb allowlist.** Every rule in every slot names its own verbs, checked against a
ceiling that the slot's name decides: `get`, `list`, `watch`, `create`, `update`, `patch`,
`delete`, `deletecollection` for a write slot, narrowed to the first three for one whose
name ends `-read`. A declaration may name any subset of that ceiling, and most do — see the
narrowing table above. Wildcards are excluded deliberately: on `roles` a wildcard verb
grants `escalate`, disabling RBAC's escalation-prevention check, and on `serviceaccounts` it
grants `impersonate`.

`leaseworker` and `flytepropeller` are on this model too, so the roles named
`<release-ns>-leaseworker` and `flytepropeller-role`, and the bindings named
`<release-ns>-leaseworker` and `flytepropeller-binding`, no longer exist. Both declared the
same `apiGroups: ['*']`, `resources: ['*']` grant, and it now lives once in the pooled
`union-work-ns` role rather than twice in roles of their own.

**One consequence of pooling that rule.** Because a pooled role is bound to every declaring
ServiceAccount, `commonServiceAccount.enabled: false` no longer keeps the operator and proxy
to their enumerated resources — on this slot they hold the wildcard too. (The wildcard itself
grants what the two roles it replaces granted, `get,list,watch,create,update,patch,delete`
and no `deletecollection`; only `flyteworkflows`, which propeller's garbage collector deletes
by label selector, carries that verb.) It reaches exactly as far as `union-work-ns` is bound,
which differs by mode:

- **At `low_privilege: false`, they are confined to the work namespaces.** `union-work-ns` is
  never bound in the release namespace in that mode, so Union's own Deployments and Secrets
  are not reachable through it, however the identities are arranged.
- **At `low_privilege: true` (the default), the release namespace *is* the work namespace**, so
  the pooled role is bound there — over Union's own objects. With the default
  `commonServiceAccount.enabled: true` this changes nothing between components, because that
  single account already held the wildcard at these verbs.
  **With `commonServiceAccount.enabled: false` it is a real widening: `operator-system`,
  `proxy-system` and `union-webhook-system` previously held only their own enumerated
  resources in the release namespace and now hold `apiGroups: ['*'], resources: ['*']`
  there**, covering Union's own Deployments and Secrets. (`union-webhook-system` joins that
  list in this release, when the pod webhook moves onto the slot model; the other two joined
  when `leaseworker` and `flytepropeller` did.) It is bounded by that namespace —
  `low_privilege: true` creates no work
  namespaces, so nothing here reaches a namespace Union does not already own outright, and no
  tenant workload is exposed to it. What it costs is blast-radius separation *between Union's
  own components* inside that one namespace, which is what splitting the identities was
  buying. Splitting identities does not narrow a pooled slot; if that separation is why you
  set the key, weigh this before upgrading.

**Read the raw diff carefully here: this is a narrowing, not a widening.** At
`low_privilege: false` the released chart bound `<release-ns>-leaseworker` — a wildcard on
every resource in every API group at `get`, `list`, `watch`, `create`, `update`, `delete`,
`patch` — with a **`ClusterRoleBinding`**, so it applied in every namespace in the cluster,
including the release namespace and `kube-system`. `flytepropeller-role` was the same shape.
What replaces them is that wildcard in a `ClusterRole` that is only ever referenced from
per-work-namespace `RoleBindings`, so it conveys nothing outside the work namespaces and
nothing at all on Union's own objects. A new `ClusterRole` appearing in the diff is what that
looks like; the object that actually granted cluster-wide access is the `ClusterRoleBinding`
that went away. Under `low_privilege: true` both were namespaced `Role`s bound in the release
namespace, and the pooled `Role` that replaces them is bound in the same place, so the change
there is one of packaging plus the identity consequence noted above.

**Measured cluster-wide, which is what matters on a shared cluster**, this is the set of
write-capable cluster-scoped grants Union's own identities hold after this release **at the
default `clusterresourcesync.clusterRoleRules: []`**. Anything you add to that key is appended
to `union-clusterresourcesync-cluster-write` and granted cluster-wide, so it belongs in your
own copy of this table:

| ServiceAccount | Grant | When |
|---|---|---|
| `union-clustersync-system` | `namespaces`, `serviceaccounts`, `resourcequotas`, `rolebindings` at `get`/`create`/`update`/`patch`; `bind` on `union-work-ns` | `clusterresourcesync.enabled` at `low_privilege: false` |
| `union-clustersync-system` | `namespaces: [delete]`, on that rule only | additionally `unionProjectSyncConfig.cleanupNamespace: true` |
| `nodeobserver-system` | `nodes: [update]` | `nodeobserver.enabled` |
| the webhook's account | `mutatingwebhookconfigurations` at `get`/`create`/`update`/`patch` | `managedConfig: false` **and** `low_privilege: false` |
| `flyte-webhook-cleanup` | `mutatingwebhookconfigurations: [get, delete]` | during a `pre-upgrade` hook only |

`leaseworker`'s and `flytepropeller`'s cluster-wide wildcards are replaced by
`list`/`watch`-only `-work-ns-cluster-read` roles, and the webhook's `ClusterRole` over
Secrets, Pods and `replicasets/finalizers` goes the same way. **The one row worth reading
twice is the first.** `clusterresourcesync` keeps cluster-wide write on three *namespaced*
resources, and that is not a narrowing this chart can make: it applies those objects into a
namespace on the sync that creates it, at which point it holds no `RoleBinding` there — it is
about to create one. What did change is the size of that grant, from twelve resources at
`verbs: ['*']` (including `secrets`, `roles` and `clusterrolebindings`) down to the four
above; `bind` is pinned by `resourceNames` to the single `union-work-ns` `ClusterRole`, so it
cannot be used to grant any other role. Every namespaced Union grant that is *not* in this
table lands in the release namespace, a namespace listed in `namespaces.static`, or one
`clusterresourcesync` provisions — never anywhere else.

"Write-capable" here means state-mutating. It excludes the `create` on `tokenreviews` and
`subjectaccessreviews` that `union-clustersync-auth-delegator` conveys through the built-in
`system:auth-delegator`: those are non-mutating authentication and authorization reviews that
happen to use `create`, and that binding is unchanged by this release.

This table covers Union-authored components. Vendored third-party RBAC — the Knative Serving
grants under `templates/gateway/` and the `kube-prometheus-stack` operator where it is enabled
— is not in scope here and is unchanged by this release.

**Grants that are gone.** From `leaseworker` and `flytepropeller`, and only at
`low_privilege: false`:

- `apiextensions.k8s.io/customresourcedefinitions` at `get`, `list`, `watch`, `create`,
  `delete`, `update`. CRDs are cluster-scoped, so only a cluster slot could carry them and
  neither component declares one — and under `low_privilege: true` the namespaced `Role` that
  held the rule never conveyed it in the first place, so the default install never had it.
  This chart installs the FlyteWorkflow CRD itself from `crds/` (or `crds/flyte-v1/` for the
  server-side-apply path), which is the supported way to manage it; see the `2026.7.x` notes
  for both install paths. **If you relied on a data-plane component creating or updating a
  CRD at runtime, this is the one grant here you must replace.**

From the operator:

- `namespaces` and `nodes` left its write rule. Both are cluster-scoped, so the namespaced
  `Role` that carried them under `low_privilege: true` never conveyed them at all. At
  `low_privilege: false` the operator keeps cluster-wide `namespaces: [list, watch]` while
  `imageBuilder.enabled` (the default). `nodes` is now read-only and only where the node
  informer actually runs — `billing.model: Legacy` or `Shadow`, with
  `disableClusterPermissions` unset — so the default `ResourceUsage` install has no `nodes`
  grant at all, and neither has write on either.

  The `nodes` read is carried by a new `<release-namespace>-operator-cluster-read`
  `ClusterRole` and its `ClusterRoleBinding`, not by `-operator-work-ns-cluster-read`: the
  informer reads nodes for usage attribution, not to reach across the namespaces tasks run
  in. Under `low_privilege` neither object is rendered — `low_privilege` forces the
  operator's `disableClusterPermissions`, so the informer never starts. Anything pinning
  that grant by role name should follow the move.
- `nonResourceURLs: [/metrics]` left its `ClusterRole`. It was emitted only at
  `low_privilege: false`, so the default install never had it.
- `post` left the `flyteworkflows` rule — `flytepropeller`'s rule, not the operator's. It is
  not a Kubernetes verb and authorized nothing.

**No Union component owns a hand-written `Role` for its general permissions any more.** The
pod webhook, `nodeobserver` and `clusterresourcesync` were the last three, and they now
declare into the same slots as everything else.

Some Union-authored RBAC is still written by hand, because slots are organized by
destination and these grants have none — **if you are auditing what this chart creates, this
is the list the slot roles do not cover**:

| Object | Why it is not a slot |
|---|---|
| the proxy's `<sa>-secret` `Role` | targets `proxy.secretsNamespace`, which is neither the release namespace nor a work namespace |
| the operator's `<sa>-secrets-watcher` `Role` | targets the control-plane namespace, same reason; only with `config.operator.secretsWatcher.enabled` |
| `union-clustersync-auth-delegator` | references the built-in `system:auth-delegator`, so there are no rules for the emitter to carry |
| `flyte-webhook-cleanup-<release-ns>`, `<release>-pre-upgrade` | hook-scoped, carrying `helm.sh/hook-delete-policy` |
| the OpenShift SCC `Role`s for imagebuilder and the Kourier gateway | grant `use` on a `SecurityContextConstraints` by name — a resource the slot model has no verb set for |

Third-party RBAC this chart authors (`templates/prometheus/`, `templates/ingress-nginx/`) and
the vendored Knative Serving grants under `templates/gateway/` are outside the model too, and
are covered in their own sections.

- **The pod webhook.** `union-webhook-role` held `apiGroups: ['*']` over
  `secrets`, `pods` and `replicasets/finalizers` at `get`/`create`/`update`/`patch`/`list`/
  `watch`, and at `low_privilege: false` a `ClusterRoleBinding` conveyed it in every namespace
  in the cluster. Those resources move to the pooled `union-work-ns` role, which is bound only
  per work namespace, so the webhook keeps exactly the reach it uses — task pods and their
  secrets — and loses the rest. Two grants stay cluster-scoped because they cannot be
  narrowed: `secrets: [list, watch]` in `union-webhook-work-ns-cluster-read`, which backs the
  Secret cache the webhook builds without a namespace filter (read-only, and not emitted at
  all under `low_privilege: true`, where the cache *is* scoped); and
  `mutatingwebhookconfigurations` in `union-webhook-cluster-write`, emitted only with
  `flytepropellerwebhook.managedConfig: false` **and** `low_privilege: false`, the one
  combination in which the webhook registers its own configuration.

- **`nodeobserver.enabled: true` now works under `low_privilege: true`, where it previously
  could not.** Its two rules were emitted as a namespaced `Role` in that mode and neither was
  conveyable by one: `nodes` is cluster-scoped, and `nodeobserver` lists pods with an empty
  namespace and a `spec.nodeName` field selector, which the API server authorizes as a
  cluster-scope check. Both now sit in cluster slots in both privilege modes —
  `union-nodeobserver-cluster-read` (`nodes: [get]`, `pods: [list]`) and
  `union-nodeobserver-cluster-write` (`nodes: [update]`). **This is the one place in the chart
  where `low_privilege: true` does not narrow a grant, and it is deliberate.** `nodeobserver`
  is off by default, so no install that has not opted in is affected.

- **`clusterresourcesync`'s grant is now derived from the templates it applies.** See the
  `clusterRoleRules` entry under Migration — this is the release's one breaking default
  change.

- **The pre-upgrade cleanup hook is split and pinned to the objects it deletes.**
  `flyte-webhook-cleanup-<release-ns>` was a single `ClusterRole` granting `get`/`delete` on
  `deployments`, `secrets` and `mutatingwebhookconfigurations` cluster-wide, with no
  `resourceNames`. The Job only ever names four literal objects, so the two namespaced kinds
  move to a `Role` and every rule is now confined by `resourceNames` to exactly those names.
  Both objects keep the same name and the same hook annotations.

  The rule worth calling out is the cluster-scoped one. Unpinned, it let the upgrade hook
  delete **any** `MutatingWebhookConfiguration` in the cluster for the duration of an
  upgrade — including a policy engine's, whose absence fails open rather than loudly. It is
  now confined to `flyte-pod-webhook`. Nothing an operator could previously clean up stops
  working: the Job's commands are unchanged, and a leftover under any other name was never
  being deleted.

### App-serving pod identity (zero trust only)

**Scope: this section applies only to `zero_trust.enabled: true`.** App serving has two
implementations. Under zero trust the chart renders the Knative workloads itself, and that is
what changes here. With zero trust off it instead emits a `KnativeServing` resource and the
Knative Operator creates those workloads — **that path is unchanged and keeps the upstream
account names.** The chart offers no ServiceAccount override there, and the `KnativeServing`
workload overrides expose no ServiceAccount field to add one through. If you run app serving
without zero trust, nothing below applies to you and no migration step is needed.

- **BREAKING: the app-serving workloads change ServiceAccount.** Upstream Knative ships three
  ServiceAccounts for six workloads: the controller, the webhook and both autoscalers all ran
  as one account named `controller`, which meant no grant could be expressed for any one of
  them without giving it to the other three. The six now have five per-component identities —
  and, as for every other component, `commonServiceAccount.enabled` decides whether they are
  used: with it on, the chart default, all six run as the single common account instead.

  | Workload | Was | Default (`commonServiceAccount.enabled: true`) | Per-component |
  |---|---|---|---|
  | `controller` | `controller` | `union-system` | `knative-controller` |
  | `webhook` | `controller` | `union-system` | `knative-webhook` |
  | `autoscaler` | `controller` | `union-system` | `knative-autoscaler` |
  | `autoscaler-hpa` | `controller` | `union-system` | `knative-autoscaler` |
  | `activator` | `activator` | `union-system` | `knative-activator` |
  | `net-kourier-controller` | `net-kourier` | `union-system` | `net-kourier` |

  `autoscaler-hpa` shares the autoscaler's identity: it is the same reconciler with a
  different PodAutoscaler class, and it held exactly the autoscaler's grants before. Kourier
  keeps its upstream name rather than gaining a `knative-` prefix — it is a separate project
  and that is the name its own manifests and issue reports use, so it is the one account whose
  name is unchanged under per-component identities.

- **Renaming an identity does not by itself change what it holds.** Splitting one account into
  five could have left the webhook and the autoscalers unauthorized, since upstream conveys
  their whole grant through roles bound to the shared `controller` account. It does not: what
  each binary is granted is set by the section below, which replaces those roles outright.

- **What each binary gains from the *identity mode* is separate from that.** With
  `commonServiceAccount.enabled: true`, the chart default, the app-serving pods run as
  `union-system` and so hold everything that account already carried for the operator, the
  proxy, the leaseworker and the rest. Nothing new is granted to the cluster; the grants are
  pooled onto one identity. That is the standing trade of a shared service account — one
  identity per install, so one cloud-side workload-identity binding — reaching app serving for
  the first time. Set `commonServiceAccount.enabled: false` to split them back out across the
  five names above, at the cost of a cloud-side binding for each.

### App-serving (Knative) RBAC (zero trust only)

**Scope: as above, this applies only when `zero_trust.enabled: true` and `apps.enabled` is not
`false`.** A dataplane that does not run app serving under zero trust is unaffected by all of
it, and so is the `knative-operator` path, which installs its own RBAC.

- **BREAKING: the vendored Knative Serving and Kourier RBAC is deleted, and the app-serving
  binaries declare into this chart's slot framework instead.** 16 hand-vendored objects go —
  10 ClusterRoles, 4 ClusterRoleBindings, 1 Role and 1 RoleBinding — and app serving becomes
  the last part of the chart whose permissions are written the same way every other
  component's are.

  | Retired | What it conveyed |
  |---|---|
  | `knative-serving-core` `ClusterRole` | cluster-wide `get,list,create,update,delete,patch,watch` on `pods`, `namespaces`, `secrets`, `configmaps`, `endpoints`, `services`, `events` and `serviceaccounts`; the same seven verbs on `apps/deployments`(+`/finalizers`), both webhook-configuration kinds, `apiextensions` CRDs(+`/status`), `autoscaling` HPAs, `coordination` leases and `caching.internal.knative.dev/images`; those seven plus `deletecollection` across `serving.knative.dev`, `autoscaling.internal.knative.dev` and `networking.internal.knative.dev`; unscoped `update` on `namespaces/finalizers`; `create` on `endpoints/restricted` |
  | `knative-serving-admin` (aggregation shell) | **any** ClusterRole anywhere in the cluster labelled `serving.knative.dev/controller: "true"`, conveyed to whichever account the controller, webhook and autoscalers ran as |
  | `knative-serving-aggregated-addressable-resolver` (aggregation shell) | the same, for `duck.knative.dev/addressable: "true"` |
  | `net-kourier` `ClusterRole` | cluster-wide `get,list,watch` on `pods`, `endpoints`, `services`, `secrets` and `configmaps`; leases CRUD; `patch` on ingresses and `update` on their status; `create,update,patch` on events |
  | `knative-serving-activator` (`Role`) + `-activator-cluster` (`ClusterRole`) | the activator's namespaced ConfigMap/Secret reads and its cluster-wide `services`, `endpoints` and `revisions` reads |
  | `knative-serving-addressable-resolver`, `-podspecable-binding` | aggregation *sources*: no union subject, but out-of-chart consumers could aggregate them |
  | `knative-serving-namespaced-admin` / `-edit` / `-view` | Knative Serving objects to anyone holding the built-in `admin`, `edit` or `view` role in a namespace, by aggregation |

  **What replaces them.** Five per-component `<release-ns>-knative-<component>-cluster-read`
  ClusterRoles — `list`/`watch` informer reads, plus exactly one `get`-only rule: the webhook's
  on the release `Namespace`, `resourceNames`-scoped to that one name — and exactly one cluster-scoped write
  role, `<release-ns>-knative-webhook-cluster-write`, whose every rule is
  `resourceNames`-scoped: one to the mutating webhook configuration, one to the two validating
  ones, and one to the release namespace's `namespaces/finalizers`. The two configuration kinds
  are separate rules on purpose — Kubernetes applies `resourceNames` across every resource in a
  rule, so naming both kinds together would have authorized six kind/name pairs instead of the
  three objects that exist. Everything else the binaries need is namespaced: a
  `comp-ns-*` Role of the binary's own in the release namespace, and the pooled `work-ns`
  role the rest of the chart shares.

  There is no aggregation left, no cert-manager or CRD grant, and **no cluster-scoped
  `create` anywhere in the set** — which is what makes the `resourceNames` scoping meaningful,
  since a `create` cannot be confined by a name that does not exist yet.

- **Measured: cluster-scoped write grants in an app-serving render drop from 118 to 4 at the
  chart default, and from 355 to 4 with per-component identities.** Counted as
  `(ServiceAccount, apiGroup, resource, verb, resourceNames)` tuples over the rendered
  fixtures, resolving each aggregated ClusterRole to what it actually aggregates. Three of the
  four are the webhook's rules above; the fourth is the pre-upgrade cleanup hook's pinned
  `delete`, which predates this and is unrelated to app serving. Every one is
  `resourceNames`-scoped.

  Two specific escalation primitives are gone with them: **cluster-wide `pods: create`**,
  which lets its holder schedule a pod under any ServiceAccount in the cluster, and
  **cluster-wide write on `serviceaccounts`, `namespaces` and `customresourcedefinitions`**.
  `kubernetes.podspec-dryrun` stays pinned `disabled`, and is now identity-mode-dependent
  rather than merely unused: the dry-run makes the webhook create a throwaway Pod in the app's
  namespace, which the shared `union-system` account can still do through the pooled work-ns
  binding, but a per-component `knative-webhook` cannot, since it declares into no
  work-namespace slot. The chart does not refuse the key; it simply is not a feature to enable
  when it works in one identity mode and not the other.

  **One grant from that role is kept and re-scoped rather than dropped: `endpoints/restricted`.**
  It is an OpenShift admission concept — `RestrictedEndpointsAdmission` refuses an `Endpoints`
  object naming a cluster-network address unless the caller holds `create` on that subresource,
  and both the autoscaler's statforwarder and the controller's serverlessservice reconciler
  write exactly such an object. It moves from one cluster-wide grant to two namespaced ones: the
  release-namespace `comp-ns-write` Role, where the statforwarder publishes its bucket, and the
  `work-ns` role, where the controller writes each revision's public Endpoints. On any
  non-OpenShift cluster it conveys nothing.

- **`autoscaling/horizontalpodautoscalers` moves from a cluster-wide write to a namespaced
  one.** `autoscaler-hpa` reconciles an HPA-class PodAutoscaler into a HorizontalPodAutoscaler
  beside the revision it scales, so the write belongs in the work namespaces and now lives in
  the pooled `work-ns` role. A cluster-wide `list`/`watch` remains, because the reconciler
  takes the shared, unfiltered HPA informer.

- **BREAKING: `net-kourier` no longer holds a cluster-wide `secrets` `list`/`watch`, and this
  one has an image floor.** Kourier used to register its Secret informer unconditionally and
  unfiltered by namespace, which made a cluster-scoped read load-bearing — a namespaced Role
  cannot authorize a cluster-scoped `LIST`. The image now gates that informer behind
  `ENABLE_INGRESS_TLS`, which **defaults to false**, and with it off the filtered-informer
  injectors register no Secret informer at all, so nothing issues the list. The chart does not
  set the env var, so no workload change accompanies this.

  **`appVersion` moves to `2026.8.4`, and that is a hard floor.** The grant is removed
  unconditionally, so the operator image must contain net-kourier `b9fbd869`
  (unionai/net-kourier#13, picked up by unionai/cloud#17870 on 2026-08-23). `2026.8.4` is the
  first release that does; every earlier build, up to and including `2026.8.3`, does not.

  Against an older image the removal is a **silent outage**: the Secret reflector loops on
  `secrets is forbidden`, its cache never syncs, the reconcilers never start — but the xDS
  readiness probe on `:18000` comes up independently, so the controller sits `1/1 Running`
  with zero restarts while every new app deployment hangs at `IngressNotConfigured`. There is
  no crash, no restart count, and no failing probe to alert on.

  The chart's own default is safe after this bump, but an **override is not**. The controller
  runs `gateway.components.kourier-controller.containers.controller.image`, which resolves to
  `image.union.tag | default .Chart.AppVersion` — so any deployment pinning `image.union.tag`,
  or overriding that component's `image.tag` directly, to a build older than `2026.8.4` must
  lift that pin in the same change as this upgrade. Nothing refuses an older tag at render
  time: the tag can legitimately be a git sha or a dev build, so the chart cannot tell. If
  you cannot move the image, stay on the previous chart version rather than removing the
  grant.

- **`knative-controller`'s digest-resolution reads on `serviceaccounts` and `secrets` are now
  namespaced — the cluster-wide `get` is gone.** Digest resolution reads the ServiceAccount
  named in the Revision's spec plus the Secrets its `imagePullSecrets` name. That was conveyed
  by a `ClusterRole` + `ClusterRoleBinding`, which let the identity `get` **any Secret in any
  namespace on the cluster**, tenant namespaces included. It never needed to be:
  `reconcileDigest` sets `k8schain.Options.Namespace` to the Revision's own namespace and
  passes a plain clientset, so these are direct, namespaced `Get`s, which is exactly what a
  per-namespace `RoleBinding` conveys. The rule now sits in `work-ns`. `resourceNames` is not usable here — both the
  ServiceAccount name and the Secret names come from the user's Revision spec.

  **Behavior change worth knowing:** digest resolution now depends on the `<release-ns>-work-ns`
  `RoleBinding` existing in the app's namespace. If it is missing, the Revision is marked
  `ContainerMissing` rather than resolving anyway — a visible failure in the Revision status,
  and one more symptom of
  [the work-namespace binding being absent](docs/rbac-union.md#the-union-work-ns-clusterrole-can-render-present-but-unbound).
  The effective grant does not change at the `commonServiceAccount.enabled: true` default, since
  `<release-ns>-work-ns` already carries `leaseworker`'s and `flytepropeller`'s resource wildcard.

  **This is not the last cluster-wide Secret read, or even the widest.** One remains,
  unchanged here and not narrowable today: the pod `webhook`, whose controller-runtime Secret
  cache is unscoped unless propeller's `limit-namespace` is set — and it reads the same config
  key propeller does, so it cannot be scoped without pinning propeller's own informer. It
  holds `list`/`watch`, which returns every Secret's contents and enumerates them besides, so
  it is broader than the named `get` this change removed. If you are auditing what this
  release still exposes, that is the row to read; it is listed with its removal condition in
  [docs/rbac-union.md](docs/rbac-union.md#where-a-secrets-rule-belongs).
  `knative-kourier`'s is gone — see the `net-kourier` bullet above.

- **The work-namespace slot is pooled, and that cuts both ways.** Each of the five also
  receives every other declarer's rules in that one role, so `commonServiceAccount.enabled:
  false` separates app serving from union's own components everywhere except the work
  namespaces. As rendered at full privilege with per-component identities:
  `knative-controller`, `knative-autoscaler` and `net-kourier` join `<release-ns>-work-ns`,
  whose first rule is `apiGroups: ["*"], resources: ["*"]`, so they hold unrestricted write in
  the work namespaces; and in the other direction the operator, proxy, leaseworker and webhook
  identities gain the Knative API groups there. The release namespace is not like this: each
  binary has its own `comp-ns-*` Role, so the activator's unconditional namespaced Secret
  informer is a Secret read for `knative-activator` and for nothing else. `knative-webhook` is
  the only one of the five that joins no work-namespace slot; `knative-activator` is the only
  one that joins neither write slot.

### Third-party subchart RBAC

The chart now writes prometheus and kube-state-metrics RBAC itself (both pinned to
`rbac.create: false`), so `low_privilege` decides it in both directions instead of only under
`low_privilege`. Rationale and per-subchart detail: [docs/rbac.md](docs/rbac.md).

Two broken metrics families are fixed, both under `low_privilege`:

- kube-state-metrics' RoleBinding named a nonexistent ServiceAccount — no `kube_*` since
  2026-05-02.
- prometheus's namespaced Role named cluster-scoped resources, which never match —
  `kubernetes-cadvisor` got `403`s, so no `container_*`.

Also, in both modes:

- `kubernetes-cadvisor` is no longer scraped under `low_privilege` — it needs cluster-wide node
  access. The Task-Level Monitoring tradeoff the flag has always described.
- kube-state-metrics collects 4 resources instead of 28 (pods, deployments, daemonsets,
  resourcequotas). `examples/values.full-privilege.yaml` adds nodes and namespaces.
- Nine cluster-wide upstream scrape jobs are dropped (`kubernetes-apiservers`, `-nodes`,
  `-nodes-cadvisor`, `-service-endpoints(-slow)`, `-services`, `-pods(-slow)`,
  `prometheus-pushgateway`). Pods and services annotated `prometheus.io/scrape` are no longer
  discovered — add a job under `prometheus.extraScrapeConfigs` if you need one.
- The "deployments available" dashboard panel gets its data — the kube-state-metrics scrape
  filter dropped the two series behind it.
- `gpu-metrics` now looks in the release namespace, where dcgm-exporter runs (was `kube-system`).
- FluentBit no longer creates a ClusterRole; it never calls the Kubernetes API here.
- ingress-nginx is confined to the release namespace (see Migration). metrics-server is
  unchanged — cluster-scoped by design.

### Migration / action required

- **Under `zero_trust.enabled: true`, the app-serving ServiceAccount names change; rebind
  anything outside the chart that referenced them.** Nothing inside the chart needs action —
  the bindings follow the names — but anything that named `controller`, `activator` or
  `net-kourier` from outside may: a cloud IAM trust policy or workload-identity binding
  scoped to one of those accounts, an admission policy that matches on the requesting user
  (`system:serviceaccount:<release-ns>:controller`), or a NetworkPolicy or audit rule keyed
  on the same.

  At the chart default all three become `union-system`, so each old reference becomes one new
  reference.

  Under `commonServiceAccount.enabled: false` the mapping is not one-to-one, and `controller`
  is the case to watch: it covered four workloads and **fans out to three accounts**, so a
  single rule keyed on it has to become three or it will stop matching the webhook and the
  autoscalers.

  | Old account | Becomes, under per-component identities |
  |---|---|
  | `controller` | `knative-controller`, `knative-webhook` **and** `knative-autoscaler` |
  | `activator` | `knative-activator` |
  | `net-kourier` | `net-kourier` — unchanged, nothing to do |

  Two kinds of install have nothing to do here: `apps.enabled` off, which is the default; and
  app serving without zero trust, where the Knative Operator owns those workloads and their
  accounts are untouched.

- **Under `zero_trust.enabled: true`, this chart no longer supplies the Knative aggregation
  roles anything outside it may have been consuming.** Three cases, all of which now need
  supplying yourself:

  - **`knative-serving-addressable-resolver` and `knative-serving-podspecable-binding`.**
    Neither had a union subject; they exist so other controllers can aggregate Knative
    Serving's `Addressable` and `PodSpecable` duck types into their own ClusterRoles. A
    controller of yours whose `aggregationRule` selects `duck.knative.dev/addressable: "true"`
    or `duck.knative.dev/podspecable: "true"` will find nothing matching after this upgrade and
    will silently lose those rules — an aggregated role with no matching source is empty, not
    an error. Ship your own labelled ClusterRole, or name the resources directly.
  - **`knative-serving-namespaced-admin` / `-edit` / `-view`.** These aggregated into the
    built-in `admin`, `edit` and `view` roles, so anyone holding one of those in a namespace
    could read — or, with `admin`/`edit`, write — Knative Serving objects there. After this
    upgrade they cannot. Grant it explicitly if your users need it; the chart should not be
    deciding who can create a `Service` in a namespace it does not own.
  - **Anything relying on `knative-serving-admin`'s aggregation.** It conveyed *any*
    ClusterRole in the cluster labelled `serving.knative.dev/controller: "true"`, so a
    third-party add-on that grants itself reach by adding that label to its own role no longer
    reaches the Knative binaries through it.

- **The webhook's grant narrows sharply, and this is the change to review before upgrading.**
  Because it ran as the shared `controller` account, `knative-webhook` previously held the
  whole of `knative-serving-core` by aggregation. It now declares only what its own informers
  and reconcilers use: ConfigMaps and Secrets in the release namespace, the two
  webhook-configuration kinds, a `get` on the release Namespace, and the two
  `resourceNames`-scoped writes. Measured, that is **167 of its 208 capability tuples
  withdrawn** — every CRD, `pods`, `serviceaccounts`, `namespaces` and Knative-API-group grant
  it never asked for. The `certificates`, `defaulting`, `validation` and `config-validation`
  controllers it runs need none of them, and admission review does not require RBAC on the
  objects being admitted. **Nothing in this chart can confirm that from the image**, and no
  snapshot can catch it: if a code path we did not find reads one of those, the webhook stays
  `1/1 Running` and every `serving.knative.dev` write is rejected by its own fail-closed
  configuration.

  The activator narrows the same way and much less: it loses `get` on `services` and
  `revisions`, keeping `list`/`watch`, which is what its informers use.

- **BREAKING: `clusterresourcesync.clusterRoleRules` now defaults to `[]`, and a `*` verb in
  it fails the render.** It used to default to twelve resources at `verbs: ['*']`, granted
  cluster-wide: `clusterrolebindings`, `configmaps`, `limitranges`, `namespaces`,
  `podtemplates`, `pods`, `resourcequotas`, `rolebindings`, `roles`, `secrets`,
  `serviceaccounts` and `services`. That was a permission set nothing derived — it was simply
  the default nobody changed — and it included the two grants that convey privilege
  escalation: a verb wildcard on `roles` conveys `escalate`, which switches off Kubernetes'
  own escalation-prevention check, and on `serviceaccounts` it conveys `impersonate`.

  The chart now derives what the component needs from the templates it actually applies:
  `namespaces`, `serviceaccounts` and `resourcequotas` (the three default
  `clusterresourcesync.templates` entries) plus `rolebindings` and `bind` for the work-ns
  binding, all at `get`/`create`/`update`/`patch`. `delete` on `namespaces` is added only
  with `clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace`.
  Those rules are chart-owned and cannot be withdrawn by an override.

  **`clusterRoleRules` is now purely an extension point, and you must set it if your own
  `clusterresourcesync.templates` or `additionalTemplates` entries create anything else.**
  Eight of the old twelve resources are no longer granted — most likely to matter are
  `limitranges`, `services`, `roles` and `clusterrolebindings`. Verbs must come from `get`,
  `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`; anything else,
  including `*`, `escalate`, `impersonate` and `bind`, fails the render with the offending
  verb named. **The failure mode if you miss this is not a failed render** — the sync is
  refused per template, per namespace, at runtime. Check your overlay for a
  `clusterresourcesync.templates` or `additionalTemplates` entry before upgrading.

- **BREAKING: `union-webhook-role` / `union-webhook-binding`, `union-nodeobserver` and
  `union-clustersync-resource` no longer exist.** Their rules are in the destination roles
  described above (`union-work-ns`, `union-webhook-work-ns-cluster-read`,
  `union-webhook-cluster-write`, `union-nodeobserver-cluster-{read,write}` and
  `union-clusterresourcesync-cluster-write`). `union-clustersync-auth-delegator` is unchanged.
  Any external tooling, audit policy or binding outside this chart that names the old objects
  must be updated.

- **At `low_privilege: true` with `flytepropellerwebhook.managedConfig: false`, the webhook no
  longer gets `mutatingwebhookconfigurations` write.** It was never usable: the propeller
  config template sets `disableCreateMutatingWebhookConfig` whenever `low_privilege` is true,
  so the binary does not self-register in that mode. This exposes rather than causes a gap in
  that combination — with `managedConfig: false` under `low_privilege`, neither Helm nor the
  webhook creates the `MutatingWebhookConfiguration`. If you run those two settings together,
  either set `managedConfig: true` or create the object yourself.

- **BREAKING: something must bind `union-work-ns` in each work namespace at
  `low_privilege: false`, and the chart cannot check that it happened.** No Union role is
  bound cluster-wide to reach work namespaces any more, so the binding is what grants
  access. Ways to arrange it:

  - **`clusterresourcesync.enabled: true` (the usual answer, and it is now automatic).** It
    already creates the work namespaces as projects are registered; it now creates the
    `union-work-ns` `RoleBinding` in each one as well. The chart adds the binding to
    `union-clusterresource-template` as `ab_work_ns_binding.yaml` — keyed to sort ahead of
    the ServiceAccount and ResourceQuota entries, so a new project is reachable before the
    objects that depend on that access are created — and grants its ServiceAccount `bind` on
    the `union-work-ns` `ClusterRole`, restricted to that one role by `resourceNames`. No
    configuration is needed and nothing is added to `clusterresourcesync.templates`, which
    stays yours to override.
  - **Static** — `namespaces.enabled: true` with a non-empty `namespaces.static`. This chart
    emits one `RoleBinding` per listed namespace. It is a single pooled role, so the count
    does not grow with the number of components or with `commonServiceAccount.enabled: false`.
    **This covers the listed names only.** `namespaces.static` is a pre-seeded subset, not the
    full set a dataplane uses, so if projects are registered after install you still need
    `clusterresourcesync` (or your own tooling) for their namespaces — the two are additive,
    not alternatives, and the grants above stay in place when both are on.
  - **Your own tooling** — if you provision work namespaces yourself, create the binding
    alongside each one: a `RoleBinding` named `union-work-ns` in that namespace, `roleRef`
    pointing at the `ClusterRole` of the same name, with one `ServiceAccount` subject per
    Union identity in the release namespace. Whatever creates that `RoleBinding` also needs
    `bind` on the `union-work-ns` `ClusterRole` — Kubernetes refuses to let a caller grant
    permissions it does not itself hold, unless it holds `bind` on the referenced role.

  If nothing creates it, the install renders clean and task pods fail with `Forbidden` the
  first time they run, not at deploy time. `low_privilege: true` deployments need no action:
  the release namespace is the work namespace and the chart binds there itself.

- **BREAKING: the per-component role names `operator-system`, `proxy-system`,
  `<release-ns>-leaseworker` and `flytepropeller-role` no longer exist**, nor do their
  bindings — `operator-system`, `proxy-system`, `<release-ns>-leaseworker` and
  `flytepropeller-binding`. Their rules moved into the destination roles above. Any external
  tooling, audit policy or `RoleBinding` outside this chart that references them by name must
  be updated.

- **At `low_privilege: false`, the operator no longer reads or writes Secrets and Deployments
  in the release namespace unless a feature that needs them is on.** It previously held
  `get`/`list`/`watch`/`create`/`update` on both there, unconditionally. They now sit in
  `union-operator-comp-ns-read` / `union-operator-comp-ns-write` behind
  `config.operator.secretsWatcher.enabled` and `config.operator.syncClusterConfig.enabled`,
  which are both off by default. `low_privilege: true` is unaffected — there the release
  namespace is the work namespace, and `union-work-ns` covers both.

- **Two new render refusals, both at `low_privilege: false`.** Listing the release namespace
  in `namespaces.static` is refused: it would bind the work-ns role where Union's own
  components run, with nothing in the render to show it. `namespaces.enabled: true` with an
  empty `namespaces.static` is refused too — it creates no bindings and pre-seeds no
  namespaces, so the render looks clean while every task fails at first execution. Both are
  ignored under `low_privilege: true`, which does not read `namespaces.static` at all.

- **BREAKING for `namespaces.enabled: false` + `low_privilege: false` — this mode becomes a
  genuine multi-namespace deployment.** If you were running that combination and relying on it
  behaving as single-namespace, it will not any more: task pods are no longer pinned to the
  release namespace (propeller returns to `limit-namespace: all`, and `namespace_mapping`
  falls back to its `{{ project }}-{{ domain }}` default unless you set
  `namespace_mapping.template`), and the single-namespace task PodTemplate, the `union`
  task ServiceAccount and the image-builder ConfigMap stop being rendered. Union's own RBAC
  does not change *because of this* — it already keyed on `low_privilege`, which this
  combination already had set to `false`; what does change it is the destination split
  above, which applies to every privilege mode. ServiceAccounts are unaffected too:
  `commonServiceAccount.enabled` defaults to `true`, so components keep sharing
  `union-system`. The one privilege
  increase is `clusterresourcesync` itself: once you enable it (see the next entry) it
  brings a ClusterRole and two ClusterRoleBindings, which is how it creates namespaces.
  **If you actually want single-namespace
  behavior, set `low_privilege: true`** — that is now the flag that means it, and
  `namespaces.enabled: false` on its own never did.

- **A `low_privilege: false` dataplane must now enable `clusterresourcesync` (or pre-create
  namespaces).** It defaults to `false` and was previously suppressed entirely in the
  `namespaces.enabled: false` mode by the `singleNamespace` gate, so leaving it off looked
  harmless. Now that the mode is genuinely multi-namespace, something has to create the
  per-project/domain namespaces as projects are registered. Either set
  `clusterresourcesync.enabled: true`, or pre-create every namespace your
  `namespace_mapping.template` can produce and enumerate them in `namespaces.static` with
  `namespaces.enabled: true`. Task pods land in `Forbidden` / `namespace not found` otherwise.

- **If you relied on `helm uninstall` deleting the pre-seeded namespaces, delete them with
  `kubectl` instead.** Helm still owns them for install and upgrade. If your namespaces are
  created outside this chart, leave `namespaces.enabled: false` rather than annotating them
  for Helm adoption.

- **Do not drop a pre-existing namespace from the manifest in the same upgrade that lands on
  this version.** Helm reads `helm.sh/resource-policy` off the live object, not off the chart
  it is about to apply. Namespaces created by an earlier version carry no annotation yet, so
  the upgrade that would first add it will happily delete them instead — with their contents —
  if that same upgrade also removes them from the render. Migrate in two steps: upgrade once
  with `namespaces.static` and `namespaces.enabled` unchanged so the annotation lands, then
  make the change that drops them (`namespaces.enabled: false`, `low_privilege: true`, or a
  shorter `static` list). GitOps users get no protection from the annotation on either step —
  see the retention note above.

- **Quoted booleans are a silent hazard on every boolean key, and the chart does not reject
  them.** Go's template engine treats any non-empty string as true, so `"false"` means
  **true**. `low_privilege: "false"` fails safe, landing on the more restrictive branch;
  `namespaces.enabled: "false"` does not — it creates every namespace in `namespaces.static`
  while the values file reads `false`. `commonServiceAccount.enabled: "false"` collapses
  per-component identities back onto the shared ServiceAccount. **If your values are
  generated, confirm the generator emits real booleans** — a `templatefile`/heredoc pipeline
  stringifies scalars, `yamlencode` does not.

- **At `low_privilege: false`, layer `examples/values.full-privilege.yaml`.** The flag grants
  the cluster-wide read; this file uses it (nodes + namespaces collectors, every namespace).
  Without it: no `kube_node_*`, no `kube_namespace_labels`, no requests/limits for task pods.
  Task pod CPU and memory are unaffected. `examples/values-legacy.yaml` already includes it.

- **ingress-nginx now watches only the release namespace**, where every Ingress this chart
  creates lives. An Ingress outside it stops being reconciled, silently. To serve one from
  elsewhere, set both `ingress-nginx.rbac.scope: false` and
  `ingress-nginx.controller.scope.enabled: false`; the chart errors if only one is set.
  Under scoped RBAC, `ingress-nginx.controller.scope.namespace` must be empty (the default)
  or name the release namespace; anything else now fails the render. The literal
  `$(POD_NAMESPACE)` is refused too, though it is what an empty value becomes — the guard
  compares namespaces, not the expressions producing them. Leave it empty.

- **One dataplane per cluster at `low_privilege: false`.** prometheus's ClusterRole and
  ClusterRoleBinding have a fixed name (`union-operator-prometheus-rbac`) but a
  release-namespace subject, so a second release contends for them. `helm install` refuses;
  ArgoCD does not unless the Application sets `FailOnSharedResource=true` — the later sync
  rewrites the subject and the first release's prometheus loses its permissions.

- **Remove `prometheus.rbac.create` and `prometheus.kube-state-metrics.rbac.create`** from your
  values. Both must stay false; the chart now refuses to render otherwise.

- **A templated `prometheus.kube-state-metrics.namespaces` entry now fails the render** under
  `low_privilege: true`. The subchart resolves it against its *own* context, so this chart
  cannot tell which namespace it becomes, and a wrong guess passes a namespace the Role never
  covers. The refusal is blanket — including `'{{ .Release.Namespace }}'`, which would in fact
  resolve correctly. Use `releaseNamespace: true` instead.

- **Four kube-state-metrics features now fail the render:** `kubeRBACProxy`,
  `customResourceState`, `autosharding` and `rbac.extraRules`. `rbac.create: false` switches
  off the permissions half of each while the feature half still deploys, so none of them was
  working — `kubeRBACProxy` additionally took the Prometheus target down by serving HTTPS to a
  plain-HTTP scrape job. Remove them. To add metrics, name the collector in
  `prometheus.kube-state-metrics.collectors`, which grants and collects together.

- **Removed keys:** `prometheus.kube-state-metrics.metricRelabelings` and
  `dcgm-exporter.namespace` — neither had any effect. If you used the latter to scrape an
  exporter outside the release namespace, that job no longer matches. Two more go with the
  app-serving work: `gateway.config.certmanager` and `gateway.config.network`. Helm does not
  error on a values key nothing reads, so an overlay still setting either is silently
  ignored rather than refused; drop them.

- **App serving is now off by default.** `apps.enabled` (and the deprecated `serving.enabled`)
  previously defaulted to *on*, so every install that set neither got Knative Serving — 32 of
  the 37 dataplane snapshot fixtures did. It now defaults off, because `low_privilege`
  defaults on and the two cannot both be true (see the next entry). **Any deployment relying
  on the default loses app serving on upgrade**, on the zero-trust *and* the legacy
  knative-operator path; set `apps.enabled: true` (plus `low_privilege: false`) to keep it.
  Check the generated overlays in `unionai/cloud` for environments that never set it
  explicitly before pinning this revision. `serving.enabled: true` still works and still takes
  effect — `apps.enabled` is left null rather than false precisely so the deprecated key keeps
  being consulted.

- **App serving now requires `low_privilege: false`, and the chart refuses the alternative.**
  The vendored Knative Serving / Kourier stack under `templates/gateway/` is 10 ClusterRoles
  and 4 ClusterRoleBindings with no namespaced form — `controller` gets its whole grant
  through an aggregated ClusterRole, `knative-serving-core` needs namespaces, CRDs and the
  webhook configurations, and the deployments take no watch-scope flag — so `low_privilege`
  cannot scope it. **An existing `zero_trust.enabled: true` install that has not set
  `low_privilege: false` will fail to render on upgrade** with a message naming both exits:
  set `low_privilege: false` to keep app serving, or `apps.enabled: false` to run without it.
  On the ArgoCD path this surfaces as a sync failure rather than a silent degradation, which
  is the intent — the alternative was a dataplane whose apps never start and nothing saying
  why. The Envoy gateway, dataproxy and tunnel-service ingress gate on `zero_trust.enabled`
  alone, so `apps.enabled: false` leaves the zero-trust dataplane fully working.
  ([docs/rbac.md](docs/rbac.md#app-serving))

- **App serving: Knative TLS certificate provisioning is gone**, at `zero_trust.enabled:
  true`. The `config-certmanager` ConfigMap and the `routing-serving-certs` `Certificate`
  are removed; TLS terminates at the Envoy gateway. `config-network` is now written
  literally — the Kourier `ingress-class` this chart vendors, and nothing else — so
  `external-domain-tls`, `cluster-local-domain-tls`, `system-internal-tls`,
  `namespace-wildcard-cert-selector` and the legacy `auto-tls` and `internal-encryption` can
  no longer be turned on. All six defaulted off, so nothing that was working stops. The
  controller's grants go with the reconciler: `knative-serving-core` no longer carries write
  on `cert-manager.io` (including cluster-scoped `clusterissuers`) or
  `acme.cert-manager.io/challenges`, nor `delete` on the `knative-serving-certmanager`
  `ClusterRole`.

- **remote_write volume shifts.** Under `low_privilege`, `kube_*` starts flowing while the nine
  dropped jobs cut the other way. At `low_privilege: false`, `container_*` joins it but the
  collector list shrinks — layer the full-privilege overlay to keep `kube_node_*`.

## 2026.8.3

`version` moves `2026.8.2` → `2026.8.3` and `appVersion` moves `2026.8.0` →
`2026.8.3`, picking up the new data-plane images.

Image changes (`2026.8.3`):

- Reusable Ray clusters now correctly share one cluster across tasks in a
  `TaskEnvironment` that sets a `pod_template`; previously each task got its
  own cluster ([unionai/cloud#17825](https://github.com/unionai/cloud/pull/17825)).

Chart changes:

- Billing is set to `none` by default for selfhosted deployments
  ([#548](https://github.com/unionai/helm-charts/pull/548)).
- Monitoring: the data-plane overview dashboard is reworked for v2 metrics, a
  v1 overview dashboard is added alongside it, new Karpenter and SLO dashboards
  ship as opt-in ConfigMaps, and a new alerting rule flags unschedulable pods
  ([#529](https://github.com/unionai/helm-charts/pull/529)).

## 2026.8.2

Chart-only release: `version` moves `2026.8.1` → `2026.8.2` while `appVersion`
stays `2026.8.0`, so the data-plane images are unchanged.

- A new opt-in `values.openshift.yaml` overlay configures rootless BuildKit with
  a dedicated service account and SCC, disables host user namespaces, uses
  `/tmp` for task working directories, persists Fluent Bit tail state, disables
  the KnativeServing Helm hook, and provisions Kourier SCC access. BuildKit and
  Kourier can use chart-created or existing SCCs
  ([#516](https://github.com/unionai/helm-charts/pull/516)).
- Leaseworker pod security context, Fluent Bit tail database path, and task/system
  service-account image pull secrets are independently configurable
  ([#514](https://github.com/unionai/helm-charts/pull/514)).
- AWS service-account identity annotations now support a configurable prefix via
  `global.AWS_POD_IDENTITY_ANNOTATION_PREFIX`; the default remains
  `eks.amazonaws.com` ([#513](https://github.com/unionai/helm-charts/pull/513)).

## 2026.8.1

Lockstep `version` bump with the `controlplane` chart (`2026.8.0` -> `2026.8.1`).
No data-plane chart changes in this release.

## 2026.8.0

Chart-only release: `version` moves `2026.7.2` → `2026.8.0` while `appVersion` stays
`2026.7.2`, so the data-plane images are unchanged. This is a **minor** bump rather than
a patch because it removes the legacy executor and retires several globals — see
Migration below.

### Removed: executor

The legacy executor Deployment has been removed ([#501](https://github.com/unionai/helm-charts/pull/501)),
completing the deprecation announced 2026-06-30.
Leaseworker is the only execution path; the control-plane chart drops the matching queue service in its
own `2026.8.0`.

- `templates/nodeexecutor/` deleted (Deployment/ConfigMap/Service/ServiceAccount)
  along with the `executor.*` helpers and the operator's executor heartbeat entry.
  Stale `config.operator.dependenciesHeartbeat.executor` overlay entries are
  dropped at render time so the operator doesn't heartbeat a nonexistent service.
- The `executor.*` values block is deleted; task log links move to
  `leaseworker.task_logs` (same defaults, same rendered `task_logs.yaml`).
  The deprecated `executor.task_logs` key still wins when an overlay sets it, so
  existing overlays keep their custom log links — migrate them to
  `leaseworker.task_logs`. All other `executor.*` overlay keys (resources,
  scheduling, `idl2Executor`, `raw_config`, …) are now ignored. The aws/gcp
  overlay `executor` blocks and the example files are updated accordingly.
- Monitoring: `union:dp:executor:active_actions` is replaced by
  `union:dp:leaseworker:active_actions`, backed by `leaseworker:active_run_leases`.
  The metrics glossary in `unionai-docs` needs a matching update.

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

- **Control-plane host: one global instead of four** ([#499](https://github.com/unionai/helm-charts/pull/499)). The DP→CP destination is now a single host global, `global.CONTROLPLANE_HOST` (moved to the top of the globals — it's the first thing to configure). Everything derives from it: the gRPC endpoint and the app-callback URL. Removed:
  - **`global.CONTROLPLANE_GRPC_ENDPOINT`** — `dataplane.cp.endpoint` derives `dns:///<host>` from `CONTROLPLANE_HOST`. The `:443` port is omitted; grpc-go's DNS resolver and Connect/HTTPS both default to 443.
  - **`global.QUEUE_GRPC_ENDPOINT`** and the **`dataplane.cp.queueEndpoint`** helper — the task-pod endpoint is injected by the leaseworker/executor from `config.union.connection`; there is no separate queue global. Authless / direct-service routing (skip nginx + OAuth, dial the in-cluster Service on `:80`) is configured explicitly via `config.union.auth` + `config.union.connection`, documented in the new **`examples/values.authless.yaml`**.
  - **`global.UNION_CONTROL_PLANE_HOST`** and the top-level **`.Values.host`** are now **DEPRECATED** — both are still honored as fallbacks (precedence `CONTROLPLANE_HOST` > `.Values.host` > `UNION_CONTROL_PLANE_HOST`) but should be migrated to `CONTROLPLANE_HOST`; they will be removed in a future release. `.Values.host` is the pre-globals top-level knob; no terraform-generated env sets it. The intracluster examples are simplified to just set `CONTROLPLANE_HOST`.

### Fully qualified image repository paths

([#509](https://github.com/unionai/helm-charts/pull/509), FAB-438.)
Every image the chart renders now spells out its registry host. An unqualified
repository (`bitnami/kubectl`) resolves against the implicit `docker.io/`
default — and one with no slash at all (`busybox`) against `docker.io/library/`.
Clusters that run an allowed-registry admission policy, or that cannot reach
Docker Hub, reject those pulls with `ErrImagePull`.

- **`image.kubectl`** — now `docker.io/alpine/k8s:1.32.3`, was `bitnami/kubectl:latest`.
  Two changes in one: the registry host is explicit, and the image moves off
  `bitnami/kubectl`, from which upstream has pruned every version tag — only
  `latest` remains, so it could not be pinned. `alpine/k8s` is what
  `flytepropellerwebhook.legacyWebhookCleanup` already used, so both Helm hooks
  now share one image. Override as usual if you mirror internally.
- **`flytepropellerwebhook.legacyWebhookCleanup.image.repository`** — now
  `docker.io/alpine/k8s`.
- **`fluentbit.testFramework.image.repository`** — new override, pinning the
  subchart's bare `busybox` default to `docker.io/library/busybox`. Rendered
  only by `helm test`. The `library/` namespace is spelled out because that is
  where official images actually live on Docker Hub; a bare `busybox` relies on
  the client to infer it.

A `make check-image-paths` gate (wired into `make test` and the `image-paths` CI
job) now fails the build on any unqualified reference, in chart values or in
rendered subchart output.

### New / improved

- **`apps.enabled` toggle for app serving components** ([#506](https://github.com/unionai/helm-charts/pull/506)).
  `apps.enabled` supersedes `serving.enabled`; a single helper resolves both with
  precedence `apps.enabled` > `serving.enabled` > `true`. Under zero trust,
  `apps.enabled: false` now also drops the vendored knative components (activator,
  autoscaler, …), which `serving.enabled: false` left rendered. `serving.enabled`
  keeps working and renders a deprecation notice at the top of the operator ConfigMap
  only when explicitly set. **No rendered-output change at default values** — migrate
  overlays at your convenience.
- **Configurable kubectl image for the Helm hook Jobs** ([#467](https://github.com/unionai/helm-charts/pull/467)).
  The pre-upgrade and pre-delete hook jobs now honor `image.kubectl` (repository, tag,
  pull policy, imagePullSecrets) instead of hardcoding the image — required for
  air-gapped clusters that mirror images internally.
- **`taskPodTemplate.workingDir`** ([#468](https://github.com/unionai/helm-charts/pull/468)).
  Sets the working directory for task pods (e.g. `/tmp`, for read-only-root-filesystem
  images) directly, instead of overriding the whole pod template to change one field.
- **Documented the embedded-secret init container image override** ([#507](https://github.com/unionai/helm-charts/pull/507)).
  A commented example under `config.core.webhook.embeddedSecretManagerConfig` shows how
  to override `fileMountInitContainer.image`, whose upstream default
  (`public.ecr.aws/docker/library/busybox:latest`) air-gapped clusters cannot reach.
  Comment-only; no rendered-output change.

### Migration / action required

- **Behavior-preserving where a deployment already sets the value.** The removed overlay keys now come from base `values.yaml` defaults. If you relied on an overlay-set value that differs from the new base default, set it in your environment values instead. The one cross-cloud behavior change is catalog-cache `use-admin-auth`, which is now consistently enabled (previously `false` in the GCP overlay).
- **fluentbit `ServiceAccount` renamed** to `union-system` (from `fluentbit-system`). No action unless you bound external policy (e.g. a cloud IAM trust) to the old ServiceAccount name.
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
