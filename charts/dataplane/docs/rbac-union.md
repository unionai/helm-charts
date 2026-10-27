# Union component RBAC

What Union's own components are allowed to do, where they may do it, and which binding
this chart cannot always create for you. For the observability subcharts — prometheus,
kube-state-metrics, opencost and the rest — see [rbac.md](rbac.md).

## Three independent axes

Three values keys are easy to confuse, because two of them used to be entangled. Each
answers a different question.

| Key | Default | Question it answers |
|---|---|---|
| `singleNamespace` | `true` | Does Union run in one namespace or many? |
| `namespaces.enabled` / `namespaces.static` | `false` / a six-name list | Which work namespaces exist at install time? |
| `commonServiceAccount.enabled` | `true` | How many identities hold the grants? |

**`singleNamespace` is the only scope axis.** It alone decides whether a component's
grant is a namespaced `Role` or a `ClusterRole`. At the `true` default every Union
workload runs in the release namespace, no route creates work namespaces, `namespaces` is
ignored, and `clusterresourcesync` is not rendered. The cluster-scoped reads that remain
are a fixed allowlist, enforced by `tests/test-rbac-guards.sh` and listed in
[rbac.md](rbac.md#what-singlenamespace-still-reads-cluster-wide). `low_privilege` is the
key's older name and still works as an alias; the chart refuses to render if both are set
and disagree.

**`namespaces.enabled` pre-seeds namespaces; it does not change scope.** It creates the
Namespace objects named in `namespaces.static` and, at `singleNamespace: false`, their
work-namespace RoleBindings. It changes no role's rules, but those bindings make the
`work-ns` grant effective in each listed namespace, so it decides *where* that grant
lands. `singleNamespace: true` ignores it.

**`commonServiceAccount.enabled` shares identity; it changes no rule.** The chart emits the
same set of roles either way, but which workload can exercise which role differs. See
[Identities](#identities).

Write these as unquoted YAML booleans. A quoted `"false"` is a non-empty string and reads
as true.

## Where grants apply: the six slots

Union's permissions are organized by *where they apply*, not by which component asked for
them. Each component declares its rules into one or more **slots**, and the chart emits
one role per slot from those declarations. Two destinations matter:

- the **components namespace** — the release namespace, holding Union's own Deployments,
  Secrets and ConfigMaps;
- the **work namespaces** — one per project/domain, holding user tasks, apps and image
  builds.

| Slot | Object | Bound by | Verbs allowed | Shared? | At `singleNamespace: true` |
|---|---|---|---|---|---|
| `comp-ns-read` | `Role` | `RoleBinding`, release ns | `get,list,watch` | per component | unchanged |
| `comp-ns-write` | `Role` | `RoleBinding`, release ns | `get,list,watch,create,update,patch,delete,deletecollection` | per component | unchanged |
| `work-ns` | `ClusterRole` | `RoleBinding` per work namespace | `get,list,watch,create,update,patch,delete,deletecollection` | **pooled** | becomes a `Role` bound in the release namespace |
| `work-ns-cluster-read` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch` | per component | **not emitted** |
| `cluster-read` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch` | per component | unchanged |
| `cluster-write` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch,create,update,patch,delete,deletecollection` | per component | unchanged |

The "verbs allowed" column is a **ceiling, not a grant**. Every rule names the verbs its
component actually calls, and most sit well below the ceiling: the pod webhook mirrors
secrets into work namespaces with `get,list,watch,create,update,patch` (omitting `delete`),
the proxy declares only `get,list,watch`, and `deletecollection` appears only on
`flyteworkflows` and the Knative API groups. Read the rendered role for what is granted.
The ceiling refuses a declaration outright if it uses wildcard verbs, `escalate`,
`impersonate` or `bind`, or if a `-read` slot names a write verb.

The slots are not the chart's whole RBAC surface. A grant falls outside them for one of
three reasons:

- The destination is a namespace the operator names, not one the emitter binds in: the
  proxy's Secret Role, the `<release-ns>-secret-read` Role for the webhook's and
  leaseworker's Secret reads beside it, and the operator's secrets-watcher Role.
- The object is a hook (the pre-upgrade cleanup).
- The verb has no slot: `use` on a named SecurityContextConstraints, for imagebuilder and
  the Kourier gateway.

Some of these do land in the release namespace. The authoritative list is the header
comment in `templates/_rbac.tpl`, which also warns against auditing by grepping for
`kind: Role`.

Role names are `<release-namespace>-<component>-<slot>`, except `work-ns`, which is pooled
and so is named `<release-namespace>-work-ns` with no component. In the usual `union`
release namespace that reads as `union-work-ns`, `union-operator-comp-ns-read`,
`union-operator-work-ns-cluster-read`, and so on. The `union-` prefix is the namespace, so
two releases in different namespaces get different role names.

**`work-ns` is a `ClusterRole` only so its rules are written once.** Every binding the
chart emits for it is a namespaced `RoleBinding`, and a `RoleBinding` that references a
`ClusterRole` confines that role's rules to the binding's own namespace. Under
`singleNamespace: false` the chart never binds `work-ns` in the release namespace, so a
component that can create any Pod in a work namespace gets no reach over Union's own
Deployments or Secrets *through that role*.

That is a property of the binding, not of the identity. The same ServiceAccount may hold
release-namespace grants from other roles: at the default `proxy.secretManager` settings the
proxy's account holds `get,list,create,update,delete` on Secrets in the release namespace
(`operator/serviceaccount-proxy-secret.yaml`), and at the shared-identity default that
account is `union-system`. To work out what an identity can do, enumerate every binding
naming it, not just the slots it declares into.

The two `cluster-*` slots survive `singleNamespace: true`, because what they carry (`nodes`,
for instance) is cluster-scoped in both modes. Narrowing it is impossible, and refusing to
render it would only move the failure to runtime. `nodeobserver` declares only cluster
slots, so it holds `ClusterRoles` even in the default posture. So does the operator, whose
node informer reads through `cluster-read` in both modes.

`work-ns-cluster-read` goes the other way. It exists for components that watch objects with
an empty namespace, which the API server authorizes as a cluster-scope check that no number
of per-namespace RoleBindings can satisfy. Under `singleNamespace` those caches are
namespace-scoped, so the slot emits nothing, and each of its reads needs a release-namespace
counterpart: usually in the pooled `work-ns` role, or in the component's own `comp-ns-read`
where only that component makes the read.

Every role in this slot is `list`/`watch` only today, but the render-time guarantee is
weaker: a slot whose name ends in `-read` admits `get`, `list` and `watch`, and the chart
refuses a write verb there. A `get` in a read slot therefore renders, and one exists:
`knative-webhook`'s `resourceNames`-pinned namespace read, in `cluster-read`. When
auditing, only the rendered role settles which read verbs it holds.

### What a declaration tells you, and what it does not

Every rule in every slot names its own verbs. In **every slot but `work-ns`** the
declaration is exact: that component gets a role of its own carrying those rules and
nothing else, so reading the declaration is reading the grant.

**One exception is easy to miss.** `clusterresourcesync`'s `cluster-write` role also
carries a `bind` rule the emitter writes itself (`dataplane.rbac.provisionerBindRule`),
`resourceNames`-pinned to `<release-ns>-work-ns`. A declared rule cannot name `bind`, so it
is not in that component's declaration. See
[Who creates the work-namespace binding](#who-creates-the-work-namespace-binding).

In `work-ns` the declaration is not exact. Every declarer is bound to the same role, so a
resource that two components both name is granted to the union of their verbs. A component
declaring `secrets: [get]` next to another declaring `secrets: [get, update, delete]` holds
all three verbs in every namespace the role is bound in. The proxy declares `get,list,watch`
and is a reader, yet it is bound to a role that carries a resource wildcard from
`leaseworker` and `flytepropeller`.

So a `work-ns` declaration states what that component **needs**, and only the rendered
`<namespace>-work-ns` role states what every declarer **gets**. Audit the rendered role.
[Pooling](#pooling) covers the same property for whole rules.

Pooling this one slot is deliberate. It means one RoleBinding per work namespace, so a
namespace created at runtime by `clusterresourcesync`, long after Helm ran, becomes
reachable by every Union component through a single object. With one object per component,
any of them could fail independently and leave the namespace half-reachable. It also means
one `bind` grant to pin by `resourceNames` instead of one per component. No other slot has
either problem, so no other slot is pooled.

### Where a `secrets` rule belongs

A cluster slot is a `ClusterRole` plus a `ClusterRoleBinding`, so a `secrets` rule there
reads every Secret in every namespace on the cluster, tenant namespaces included. It is the
broadest grant this chart can express. Declare one only when the component's read is a
namespace-less `LIST` from an unscoped informer, which the API server authorizes at cluster
scope or not at all.

**A namespace unknown at render time is not a reason to use a cluster slot.** `work-ns`
exists for that case: a `ClusterRole` bound per namespace authorizes an ordinary namespaced
`Get` in a namespace created long after Helm ran. The test is *how the read is made*, not
*where*. `knative-controller`'s image-digest reads sat in `cluster-read` for the "unknown
namespace" reason and are now in `work-ns`, with the same reach.

One component holds a cluster-wide `secrets` rule that cannot be narrowed today:

| Component | Why | Goes away when |
|---|---|---|
| `webhook` | the pod webhook's controller-runtime Secret cache is scoped only when propeller's `limit-namespace` is set to something other than `all`. The webhook reads the same config key propeller does, so scoping it would pin propeller's own cluster-wide informer. Scoping the cache also breaks the mirroring it exists for: the secret manager reads the mirrored Secret out of the admitted pod's own namespace through that cache | `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled: false` drops it today, along with the mirroring |

`knative-kourier` used to be a second row. net-kourier registered its Secret informer
unconditionally and unfiltered by namespace, so the cluster-scoped `LIST` was load-bearing.
The image now gates that informer behind `ENABLE_INGRESS_TLS`, which defaults to false and
registers no Secret informer while off, so the rule is gone. Setting that env var on
`net-kourier-controller` brings the informer back and requires the grant; this chart leaves
it unset.

### Cluster reads gated on the code path that makes them

Outside single-namespace mode, the chart grants a cluster-wide read only under the values
that start the code path using it. Where that gate is more than "the component is enabled",
it is:

| Role | Resource | Granted when | Why | Under `singleNamespace` |
|---|---|---|---|---|
| `union-operator-cluster-read` | `nodes` `list,watch` | `disableClusterPermissions` off, and billing model not `None` or `collectUsages.enabled` or `serverlessCollectUsages.enabled` (via `config.configOverrides`) | the operator's node informer, which startup waits on | the same grant, on the same gate: nodes are cluster-scoped, so it is on the single-namespace allowlist |
| `union-operator-cluster-read` | `nodes` `get,list,watch` | `config.operator.clusterHealth.nodeCapacity.enabled`, whatever the row above says | the cluster health snapshot's capacity report; it adds `get` to the same `nodes` rule | the same grant, on the same gate, on the single-namespace allowlist |
| `union-operator-cluster-read` | `pods` `get,list,watch` | `nodeCapacity.enabled` and `nodeCapacity.clusterWidePods` | the capacity report's per-pool usage, read cluster-wide because a namespace-limited operator's pod cache sees only its own namespace | the same grant, on the same gate, on the single-namespace allowlist |
| `union-operator-cluster-read` | `nonResourceURLs: /metrics` `get` | always | the work queue's API-server scrape, which feeds its FlyteWorkflow-count and etcd-size throttles | not granted, matching the chart before the slot model, whose single-namespace Role could not convey it; the throttles stay off there |
| `union-operator-work-ns-cluster-read` | `metrics.k8s.io` `pods` `list` | `collectUsages.enabled`, billing model `ResourceUsage` or `Shadow`, or `serverlessCollectUsages.enabled` with cluster permissions | the usage aggregators' pod-metrics list | `union-operator-comp-ns-read`, on the same conditions |
| `union-flytepropeller-work-ns-cluster-read` | `namespaces` `list` | propeller's `limit-namespace` is empty, `all` or `all-namespaces` | the workflow garbage collector, which cannot delete anything if the List fails | not needed; the collector reads only the release namespace |
| `union-leaseworker-work-ns-cluster-read` | `events.k8s.io` `events` `list,watch` | always | the shared Kubernetes event watcher (`leaseworker/plugin/k8s/event_watcher.go`), a raw informer that watches every namespace when no limit namespace is set; if refused, event enrichment stays empty and startup proceeds | not needed: since cloud#18782 the informer takes the limit namespace, so `work-ns` covers it. A leaseworker image without that change watches cluster-wide and is refused |
| `union-leaseworker-work-ns-cluster-read`, `union-flytepropeller-work-ns-cluster-read` | whatever `taskPluginClusterReadRules` lists, `list,watch` | the key is set | CRD-backed task plugins' informers, which watch every namespace; see [rbac.md](rbac.md#plugin-crd-reads-at-singlenamespace-false) | not granted or needed: plugin informers are confined to the release namespace, which `work-ns` covers |
| `union-operator-work-ns-cluster-read` | `configmaps` `list,watch` | `apps.enabled` | see below | covered by `work-ns` |
| `union-operator-work-ns-cluster-read` | `policy` `poddisruptionbudgets` `list,watch` | `apps.enabled` and `config.operator.apps.controller.podDisruptionBudget.enabled` | see below | `work-ns`, under the same gate, beside the writes |

The last two rows are stopgaps. The apps controllers read the `connector-config` ConfigMap
in the release namespace, and each app's PodDisruptionBudget, through a controller-runtime
cache that is not namespace-scoped outside single-namespace mode. The first `Get` starts a
cluster-wide informer and blocks until it syncs. The ConfigMap grant goes away once the
operator reads it through the manager's API reader or scopes the ConfigMap cache to the
release namespace. The PodDisruptionBudget lives in each app's work namespace, which no
cache entry can name in advance, so only the API reader removes that grant.

With PodDisruptionBudget management on, `work-ns` also carries `create`, `update` and
`delete` on `poddisruptionbudgets`, so the operator can manage each app's PDB in its work
namespace.

### Release-namespace grants do not come from `work-ns`

At `singleNamespace: false` the release namespace is not a work namespace and `work-ns` is
not bound there, so every call a component makes into the release namespace needs its own
`comp-ns-read` or `comp-ns-write` rule. Without one, a call succeeds only by accident:
through the proxy's Secret Role when every component shares `union-system` with the proxy.
With per-component ServiceAccounts, or a secret manager other than `K8s`, it is denied.
Each component therefore declares the calls it makes:

| Role | Grant | Granted when | Code path |
|---|---|---|---|
| `union-operator-comp-ns-read` | `apps` `deployments`, `daemonsets`, `statefulsets` `get,list,watch` | always | the cluster health snapshot, which reports every Union workload in the release namespace |
| `union-operator-comp-ns-read` | `configmaps` `get,list,watch` on `union-operator`; `secrets` `list,watch` | `imageBuilder.enabled` | the image builder's reference-ConfigMap informer and mirror-secrets deleter, both of which startup waits on |
| `union-operator-comp-ns-write` | `secrets` `get,update` on `operator.secretName` | `operator.enableTunnelService` | the tunnel token Secret |
| `union-operator-comp-ns-write` | `secrets` `create`; `get,update` on the API key state Secret | `config.operator.apiKey.enabled` | the Eager API key cache |
| `union-operator-comp-ns-write` | `configmaps` `update` on `connector-config` | `apps.enabled` | the apps controllers' connector registry |
| `union-webhook-comp-ns-read`, `-comp-ns-write` | `pods` `get`; `replicasets/finalizers` `update` | `singleNamespace: false` and `flytepropellerwebhook.managedConfig: false` | registering the MutatingWebhookConfiguration with the pod's ownerReferences |
| `union-webhook-comp-ns-write` | `secrets` `create`; `get,update` on the certificate Secret | `flytepropellerwebhook.certificate.provider: legacy` | the `init-certs` init container |
| `<release-ns>-secret-read` in `proxy.secretsNamespace` | `secrets` `get` | the webhook's secret manager type is `K8s`, except under `singleNamespace` with the secrets in the release namespace | the webhook's secret injection and the leaseworker connector plugin's secret reads |

Under `singleNamespace: true` these overlap with `work-ns`, which is bound in the release
namespace there. The chart emits them anyway, except the two whose code path only runs
outside that mode, so that a component's release-namespace access does not depend on
another component's wildcard.

### Pooling

**`work-ns` is the only pooled slot.** Every other slot emits one role per declaring
component, carrying that component's rules alone.

The pooled role is bound to every ServiceAccount that declares into it and holds the
*union* of every declarer's rules, so each declarer effectively holds every other
declarer's rules in that destination. Splitting identities does not split this.
`leaseworker` and `flytepropeller` each declare a resource wildcard into `work-ns`, so
wherever either is enabled every other `work-ns` declarer inherits it. At
`singleNamespace: false` that reach is confined **to work namespaces**, the only place the
role is bound. At `singleNamespace: true` the release namespace *is* the work namespace, so
the reach extends over Union's own objects, which is the trade that mode makes.

The release-namespace slots used to be pooled the same way, at a concrete cost: the Knative
activator's namespaced Secret informer, an unconditional `init()` registration in that
binary, put `secrets: get,list,watch` in the shared `comp-ns-read` role, which every other
declarer was bound to. Under per-component roles that read stops at `knative-activator`.
When comparing against an earlier release, the same rules are now spread across one object
per component, named `<release-ns>-<component>-comp-ns-{read,write}`.

## Who creates the work-namespace binding

Under `singleNamespace: false`, something must create a `RoleBinding` named
`<release-ns>-work-ns` in each work namespace. There are three routes, which can be
combined:

- **this chart**, when `namespaces.enabled: true` and `namespaces.static` is non-empty —
  one RoleBinding per listed namespace, created at install;
- **`clusterresourcesync`**, when enabled — it creates each work namespace as a project is
  registered, and the chart hands it the RoleBinding as an entry in its
  clusterresource-template ConfigMap, keyed `ab_work_ns_binding.yaml` so it is applied
  immediately after the Namespace itself;
- **your own tooling**, if you provision work namespaces yourself.

`namespaces.static` is a *subset*: projects registered after install get their namespaces
from `clusterresourcesync` regardless. The chart therefore emits the provisioner's grant in
**both** postures, and where both routes cover a namespace they produce the identical
object.

Whatever creates the binding also needs `bind` on the `<release-ns>-work-ns` ClusterRole,
because Kubernetes lets a caller grant only permissions it holds itself. Creating the
RoleBinding fails without `bind` even when every other permission is in place. The chart
grants `clusterresourcesync` exactly that, pinned by `resourceNames` to the one role, so it
can bind that role alone and never holds the role's own permissions.

### The `union-work-ns` ClusterRole can render present but unbound

**This is the most confusing consequence of the model, and on its own it is not a defect.**

At `singleNamespace: false` with `namespaces.enabled: false` — the default multi-namespace
posture — the `union-work-ns` ClusterRole renders with **no binding at all**. That is
expected *provided one of the runtime routes above is in play*: `clusterresourcesync`
creates the per-namespace RoleBindings as it provisions each namespace, and a
`helm template` run cannot show an object that does not exist yet.

It is a defect when no route is in play. `clusterresourcesync.enabled` also defaults to
`false`, so `singleNamespace: false` alone, with `namespaces.enabled` left at `false` and
no external provisioner, renders the same unbound ClusterRole and never binds it. That
render is indistinguishable from the healthy one, which is why the check below runs on the
cluster and not on the manifest.

Three things follow.

**A render cannot show whether the binding landed.** The install renders green and a GitOps
controller reports healthy; the first sign of trouble is a task execution failing with
`Forbidden`. After registering a new project, confirm the binding:

```bash
kubectl get rolebinding <release-ns>-work-ns -n <work-namespace>

# The subjects are not always union-system — read them off the binding rather
# than assuming, since they differ under commonServiceAccount.enabled: false.
kubectl get rolebinding <release-ns>-work-ns -n <work-namespace> \
  -o jsonpath='{.subjects[*].name}'

kubectl auth can-i create pods -n <work-namespace> \
  --as=system:serviceaccount:<release-ns>:<one of those subjects>
```

If the binding is missing, check `clusterresourcesync`'s logs for errors applying
`ab_work_ns_binding.yaml`. If you provision namespaces yourself, you owe each one that
RoleBinding, with `roleRef` pointing at the ClusterRole of the same name.

**The binding's subjects are only the accounts that declare into the `work-ns` slot**, and
which those are depends on what is enabled: four under split identities with apps off, seven
with zero-trust app serving. Never compose the list by hand. Copy it from a chart-rendered
binding instead: `helm template --set namespaces.enabled=true`, or the
`ab_work_ns_binding.yaml` entry in `clusterresourcesync`'s ConfigMap. An account that does
not declare into the slot receives the pooled role's full write set in every work
namespace. That includes `clusterresourcesync`, which holds `bind` on this role precisely so
it can hand the role out without holding it.

**A capability audit of this chart is valid only where the pooled slot is bound.** An audit
that walks bindings reports the entire contents of `union-work-ns` as lost when it runs
against a render where that role is unbound, which is the default multi-namespace render.
That looks like a catastrophic regression and is a measurement artifact. Audit against a
posture with the bindings present (`--set namespaces.enabled=true`, or a live cluster after
the first sync), and key capability tuples on `(serviceaccount, scope, apiGroup, resource,
verb)` without collapsing the scope column: a grant held in a *work* namespace does not
substitute for one missing in the *release* namespace.

## The cluster-scoped write surface

Most of what this chart grants is namespaced. The cluster-scoped, state-mutating grants
held by Union identities are these. Their conditions are compatible: a multi-namespace
zero-trust install with `clusterresourcesync`, `nodeobserver`, `nodeBootstrap` and an
unmanaged pod-webhook config renders all six at once, so treat the table as the maximum
surface.

| ClusterRole | Rendered when | Grant |
|---|---|---|
| `flyte-webhook-cleanup-<release-ns>` | always (upgrade hook) | `get`/`delete` on one named `MutatingWebhookConfiguration` |
| `union-clusterresourcesync-cluster-write` | `singleNamespace: false` + `clusterresourcesync.enabled` | get/create/patch on `namespaces`, `serviceaccounts`, `resourcequotas`, `rolebindings`; `bind` on `<release-ns>-work-ns` |
| `union-nodeobserver-cluster-write` | `nodeobserver.enabled` (either scope mode) | `update` on `nodes` |
| `union-node-bootstrap-cluster-write` | `nodeBootstrap.enabled` with `nodeBootstrap.startupTaintKey` set (either scope mode) | `update` on `nodes`, to remove the startup taint from its own node |
| `union-webhook-cluster-write` | `singleNamespace: false` + `flytepropellerwebhook.managedConfig: false` | `create` on `mutatingwebhookconfigurations`; `get`/`update` on the one it registers, named by `config.core.webhook.serviceName` |
| `union-knative-webhook-cluster-write` | app serving under zero trust | `update` on three named webhook configurations, plus `namespaces/finalizers` on the release namespace |

`clusterresourcesync`'s is the irreducible one: it applies ServiceAccounts and
ResourceQuotas *into a namespace on the sync that creates it*, before any RoleBinding
exists there, so those rules cannot be namespaced. The controller applies with a create and,
when the object already exists, a get and a patch, so the rules carry exactly those verbs.
Its `namespaces` rule gains `delete` only under
`clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace: true`.

The pod webhook's row is as narrow as its registration call allows. It creates its
MutatingWebhookConfiguration and, if one already exists, gets and updates it; those are its
only verbs. `get` and `update` are pinned by `resourceNames` to the name it registers
under. `create` cannot be pinned, since the name does not exist before the object does.

**What the `clusterresourcesync` row still leaves.** Its `rolebindings` write is
cluster-wide, because RBAC cannot confine a namespaced write to a subset of namespaces, and
`<release-ns>-work-ns` is a resource-wildcard role. A compromised `clusterresourcesync`
could therefore plant a `<release-ns>-work-ns` RoleBinding in a namespace this release does
not own, giving Union's ServiceAccounts admin over it. **The `bind` pin caps what it can
grant directly, not where that grant leads.** The pin means no stronger role can be
substituted, and `namespaces` `delete` stays off unless `cleanupNamespace` is on, so it
cannot destroy a tenant namespace. But `<release-ns>-work-ns` carries `pods: create`, and
creating a pod in a namespace conveys the permissions of every ServiceAccount already in
it. Bound into a namespace that holds a stronger identity, such as `kube-system` on a stock
cluster, that is a route past the ceiling the pin appears to set. The pin closes direct
substitution only.

This is the accepted cost of provisioning namespaces at runtime. You can avoid it or bound
it. **To avoid it,** turn `clusterresourcesync` off and handle namespace provisioning and
project mapping with something you trust. Pre-seeding with `namespaces.enabled: true` and
`namespaces.static` is not enough on its own: static namespaces are a pre-seeded *subset*,
so projects registered after install are still provisioned at runtime and both halves of the
grant stay. **To bound it while keeping it,** use an admission policy (Kyverno,
OPA/Gatekeeper) that restricts its RoleBinding and Namespace writes to your
project-namespace naming convention. Only an admission policy can express that constraint
on the *shape* of what it creates; re-cutting the RBAC cannot.

That row is also the one you can extend. Anything set in
`clusterresourcesync.clusterRoleRules` — the escape hatch for resource types your own
`templates` or `additionalTemplates` entries create — is appended to that same ClusterRole,
cluster-wide, and the allowlist it passes through permits `create`, `update`, `patch`,
`delete` and `deletecollection`. It refuses a wildcard *verb* and an all-groups
`apiGroups: ["*"]`, but accepts a resource wildcard inside a named group, so
`apiGroups: [""], resources: ["*"], verbs: [get]` renders and reads every core resource,
Secrets included. Audit that key alongside this table.

Beyond this table and that key, every cluster-scoped grant held by a Union identity is
**read-only**. `clusterresourcesync` holds no `system:auth-delegator` binding: the
controller serves only unauthenticated metrics and pprof and makes no TokenReview or
SubjectAccessReview.

Under `singleNamespace: true` only three rows of this table can render: the upgrade hook's,
which is pinned to one name, and nodeobserver's and node-bootstrap's, the two unpinned
cluster-scoped writes the mode allows. RBAC cannot pin either to the node the pod runs on.
`tests/test-rbac-guards.sh` asserts exactly that.

`singleNamespace` is not a whole-chart namespace boundary; see
[rbac.md](rbac.md#the-rule). A namespace-confined install identity is not enough to deploy
this chart.

## Identities

At the `commonServiceAccount.enabled: true` default, one ServiceAccount, `union-system`, is
the subject of nearly every binding the chart emits. That includes the Knative control-plane
grants, now that app serving runs on per-binary identities, on top of the operator, proxy,
leaseworker, pod webhook, image builder and dataproxy grants.

Net cluster capability is the same either way; what changes is **concentration**. Setting
`commonServiceAccount.enabled: false` gives each component its own account:

| Component | Dedicated name |
|---|---|
| operator | `operator-system` |
| operator proxy | `proxy-system` |
| leaseworker | `leaseworker` |
| pod webhook | `union-webhook-system` |
| buildkit | `union-imagebuilder` |
| flyteconnector | `flyteconnector` |
| dataproxy | `dataproxy-system` (zero trust only) |
| Knative controller / webhook / autoscaler / activator | `knative-controller`, `knative-webhook`, `knative-autoscaler`, `knative-activator` (app serving under zero trust only) |
| Kourier controller | `net-kourier` (same) |

**Each new name needs a cloud-side workload-identity binding before those workloads can
authenticate**: an IRSA trust-policy subject on AWS, a `roles/iam.workloadIdentityUser`
member on GCP, or an Azure federated credential. If you flip the flag first, the pods keep
running but cannot reach cloud storage.

`nodeobserver`, `clusterresourcesync`, `flytepropeller` and `node-bootstrap` ignore the
flag: they always hold dedicated accounts (`nodeobserver-system`, `union-clustersync-system`,
`flytepropeller-system`, `union-node-bootstrap`).

**`fluentbit` is the documented exception.** Its account name comes from the subchart key
`fluentbit.serviceAccount.name`, which this chart pins to `union-system`. That pin wins
over the per-component fallback, so fluentbit runs as `union-system` unless you also set
that key to a dedicated name.

It declares no Kubernetes permissions (`fluentbit.rbac.create` is `false`, and it calls no
Kubernetes API with this chart's config), but it can still hold them. **At the
`commonServiceAccount.enabled: true` default it holds everything bound to `union-system`,
including the pooled `work-ns` role.** That matters more here than elsewhere, because
fluentbit is a DaemonSet on every node.

Splitting identities removes those grants; renaming does not. At
`commonServiceAccount.enabled: false` the slot bindings name the dedicated accounts, so the
`union-system` account fluentbit still gets is the subject of no binding and holds no
grants. To isolate fluentbit while keeping the shared account, set that key to a dedicated
name and provision the account yourself.

### Knative ServiceAccount naming

Two details surprise people reading a render:

- **`net-kourier` keeps its literal name** while its ClusterRole is
  `union-knative-kourier-cluster-read`. The role name follows the chart's slot convention;
  the account name is upstream's and is preserved deliberately.
- **The old shared `controller` account fans out to three accounts.** It ran the
  controller, the webhook and both autoscalers. Under per-component identities those
  become `knative-controller`, `knative-webhook` and `knative-autoscaler`, so any external
  rule, policy or trust relationship keyed on `controller` must become three, or it stops
  matching the webhook and the autoscalers. `autoscaler-hpa` shares the autoscaler's
  account: it is the same reconciler under a different PodAutoscaler class.

## Two RBAC subtleties worth knowing

Both are counter-intuitive, and both have produced real defects in this chart.

**A subresource must be named in its own right.** Granting `endpoints` does *not* convey
`endpoints/restricted`. On OpenShift, writing an Endpoints object that names a pod IP
requires `create` on `endpoints/restricted`, so a rule that looks complete fails at
runtime. The same applies to every `<resource>/status` and `<resource>/finalizers`.

**`resourceNames` applies across the cartesian product of a rule's resources.** A single
rule naming two resource kinds and three names claims all six kind/name pairs, not three.
So a rule like

```yaml
- apiGroups: [admissionregistration.k8s.io]
  resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations]
  resourceNames: [a, b, c]
```

claims more than it appears to. Split it into one rule per resource when the names differ
by kind. Every Union-authored rule in this chart that sets `resourceNames` names a single
resource; check that property of any render with one pass over its `Role` and `ClusterRole`
documents.

## One failure that does not look like RBAC

If task pods fail with `ImagePullBackOff` or `ErrImagePull` on images from a private
registry, suspect a missing work-namespace binding before suspecting the registry.

The pod webhook mirrors image-pull secrets into each work namespace. If the mirror is
forbidden, the webhook swallows the `Forbidden` and admits the pod without its secret. The
failure surfaces at image pull, and the pod's events show only the pull error. The one trace
is in the webhook's own log:

```bash
kubectl logs -n <release-ns> deploy/union-pod-webhook
```

Each of these renders green and still produces this failure: `clusterresourcesync` enabled
but crash-looping or not yet past its first sync; your own tooling broken or lagging;
`namespaces.static` missing the namespace the task landed in. Confirm the binding exists in
the affected namespace before looking anywhere else.
