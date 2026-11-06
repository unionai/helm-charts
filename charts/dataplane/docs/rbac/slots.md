# Union component RBAC

This page covers how Union's own components declare their grants, how the chart turns those
declarations into roles, and where a rule belongs.

## Where grants apply: the six slots

Union's permissions are organized by where they apply. Each component declares its rules
into one or more slots, and the chart emits one role per slot from those declarations. There
are two destinations:

- The release namespace holds Union's own Deployments, Secrets and ConfigMaps.
- The work namespaces, one per project and domain, hold user tasks, apps and image builds.

| Slot | Object | Bound by | Verbs allowed | Shared? | At `singleNamespace: true` |
|---|---|---|---|---|---|
| `comp-ns-read` | `Role` | `RoleBinding`, release ns | `get,list,watch` | per component | unchanged |
| `comp-ns-write` | `Role` | `RoleBinding`, release ns | `get,list,watch,create,update,patch,delete,deletecollection` | per component | unchanged |
| `work-ns` | `ClusterRole` | `RoleBinding` per work namespace | `get,list,watch,create,update,patch,delete,deletecollection` | **pooled** | becomes a `Role` bound in the release namespace |
| `work-ns-cluster-read` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch` | per component | **not emitted** |
| `cluster-read` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch` | per component | unchanged |
| `cluster-write` | `ClusterRole` | `ClusterRoleBinding` | `get,list,watch,create,update,patch,delete,deletecollection` | per component | unchanged |

The "verbs allowed" column is a ceiling that no rule has to reach. Every rule names the verbs
its component actually calls, and most sit well below the ceiling. The pod webhook mirrors
secrets into work namespaces with `get,list,watch,create,update,patch`, which omits `delete`.
The proxy declares only `get,list,watch`, and `deletecollection` appears only on
`flyteworkflows` and the Knative API groups. Read the rendered role for what is granted. The
chart refuses a declaration outright if it uses wildcard verbs, `escalate`, `impersonate` or
`bind`, or if a `-read` slot names a write verb.

Some grants fall outside the slots, for one of three reasons:

- The destination is a namespace the operator names, not one the emitter binds in. Examples
  are the proxy's Secret Role, the `<release-ns>-secret-read` Role for the webhook's and
  leaseworker's Secret reads beside it, and the operator's secrets-watcher Role.
- The object is a hook, the pre-upgrade cleanup.
- The verb has no slot. `use` on a named SecurityContextConstraints is one, for imagebuilder
  and the Kourier gateway.

Some of these do land in the release namespace. The authoritative list is the header
comment in `templates/_rbac.tpl`, which also warns against auditing by grepping for
`kind: Role`.

Role names are `<release-namespace>-<component>-<slot>`, except `work-ns`. That role is
pooled, so its name is `<release-namespace>-work-ns` with no component. In the usual `union`
release namespace that reads as `union-work-ns`, `union-operator-comp-ns-read`,
`union-operator-work-ns-cluster-read`, and so on. The `union-` prefix is the namespace, so
two releases in different namespaces get different role names.

`work-ns` is a `ClusterRole` only so that its rules are written once. Every binding the
chart emits for it is a namespaced `RoleBinding`, and a `RoleBinding` that references a
`ClusterRole` confines that role's rules to the binding's own namespace. Under
`singleNamespace: false` the chart never binds `work-ns` in the release namespace. A
component that can create any Pod in a work namespace therefore gets no reach over Union's
own Deployments or Secrets through that role.

That limit belongs to the binding. The same ServiceAccount may hold release-namespace grants
from other roles. At the default `proxy.secretManager` settings the proxy's account holds
`get,list,create,update,delete` on Secrets in the release namespace, through
`operator/serviceaccount-proxy-secret.yaml`, and at the shared-identity default that account
is `union-system`. To work out what an identity can do, enumerate every binding that names
it, including those outside the slots it declares into.

The two `cluster-*` slots survive `singleNamespace: true`, because what they carry, such as
`nodes`, is cluster-scoped in both modes. The grant cannot be narrowed, and refusing to
render it would only move the failure to runtime. `nodeobserver` declares only cluster slots,
so it holds `ClusterRoles` even in the default posture. The operator does too, because its
node informer reads through `cluster-read` in both modes.

`work-ns-cluster-read` is emitted only at `singleNamespace: false`. It exists for components
that watch objects with an empty namespace, which the API server authorizes as a
cluster-scope check that no number of per-namespace RoleBindings can satisfy. Under
`singleNamespace` those caches are namespace-scoped, so each of the slot's reads needs a
release-namespace counterpart. The counterpart is usually in the pooled `work-ns` role, or in
the component's own `comp-ns-read` where only that component makes the read.

Every role in this slot holds only `list` and `watch` today, but the render-time guarantee is
weaker. A slot whose name ends in `-read` admits `get`, `list` and `watch`, and the chart
refuses a write verb there. So a `get` in a read slot renders, and one exists:
`knative-webhook`'s `resourceNames`-pinned namespace read, in `cluster-read`. When auditing,
only the rendered role settles which read verbs it holds.

## What a declaration tells you, and what it does not

Every rule in every slot names its own verbs. In every slot but `work-ns` the declaration is
exact. That component gets a role of its own carrying those rules and nothing else, so
reading the declaration is reading the grant.

The exception is the `cluster-write` role of `clusterresourcesync`. It also carries a `bind`
rule that the emitter writes itself, through `dataplane.rbac.provisionerBindRule`, pinned by
`resourceNames` to `<release-ns>-work-ns`. A declared rule cannot name `bind`, so the rule is
absent from that component's declaration. See
[Who creates the work-namespace binding](work-namespaces.md#who-creates-the-work-namespace-binding).

In `work-ns` the declaration understates the grant. Every declarer is bound to the same role, so a
resource that two components both name is granted to the union of their verbs. A component
declaring `secrets: [get]` next to another declaring `secrets: [get, update, delete]` holds
all three verbs in every namespace the role is bound in. The proxy declares `get,list,watch`
and is a reader, yet it is bound to a role that carries a resource wildcard from
`leaseworker` and `flytepropeller`.

So a `work-ns` declaration states what that component needs, and only the rendered
`<namespace>-work-ns` role states what every declarer gets. Audit the rendered role.
[Pooling](#pooling) covers the same property for whole rules.

Pooling this one slot is deliberate. It means one RoleBinding per work namespace. A
namespace created at runtime by `clusterresourcesync`, long after Helm ran, therefore becomes
reachable by every Union component through a single object. With one object per component,
any of them could fail independently and leave the namespace half-reachable. It also means
one `bind` grant to pin by `resourceNames` instead of one per component. No other slot has
either problem, so no other slot is pooled.

## Pooling

`work-ns` is the only pooled slot. Every other slot emits one role per declaring component,
carrying that component's rules alone.

The pooled role is bound to every ServiceAccount that declares into it. It holds the union
of every declarer's rules, so each declarer effectively holds every other declarer's rules in
that destination. Splitting identities does not split this. `leaseworker` and
`flytepropeller` each declare a resource wildcard into `work-ns`, so wherever either is
enabled every other `work-ns` declarer inherits it. At `singleNamespace: false` that reach is
confined to work namespaces, the only place the role is bound. At `singleNamespace: true` the
release namespace is the work namespace, so the reach extends over Union's own objects, which
is the trade that mode makes.

Before this change the release-namespace slots were pooled the same way, which had a
concrete cost. The Knative activator's namespaced Secret informer, an unconditional `init()`
registration in that binary, put `secrets: get,list,watch` in the shared `comp-ns-read` role,
and every other declarer was bound to it. Now that read stops at `knative-activator`. When
comparing against an earlier release, expect the same rules to be spread across one object
per component, named `<release-ns>-<component>-comp-ns-{read,write}`.

## The work-ns wildcard

The pooled `<release-ns>-work-ns` role grants `apiGroups: ['*']` and `resources: ['*']` with
every verb except `deletecollection`. That is deliberate, and the wildcard is not the
security boundary.

Any identity that can create a pod in a namespace is already admin of that namespace. The
pod can name any ServiceAccount there and mount any Secret there, so it acts with every
permission those identities hold. Union's components create task pods in every work
namespace, so they hold that power whatever the rest of the rule list says. Narrowing
`work-ns` to named resources would make the role harder to read and no safer.

The boundary is in two other places:

- **Where `work-ns` is bound.** At `singleNamespace: false` it is bound only in the work
  namespaces, by a RoleBinding that the chart, `clusterresourcesync` or your own tooling
  writes in each one ([work-namespaces.md](work-namespaces.md#who-creates-the-work-namespace-binding)).
  - The release namespace, which holds Union's own Deployments and Secrets, never gets the
    binding, and the chart refuses a `namespaces.static` that lists it.
  - Each component's release-namespace access comes from its own `comp-ns-read` and
    `comp-ns-write` Roles.
- **The cluster-scoped grants.** [cluster-writes.md](cluster-writes.md)
  lists them rule by rule. In single-namespace mode they are held to the
  [single-namespace allowlist](scope.md#what-singlenamespace-still-reads-cluster-wide).

The all-groups wildcard exists only in `work-ns`. `dataplane.rbac.emitSlot` refuses
`apiGroups: ['*']` in every other slot, and `tests/test-rbac-guards.sh` checks every
rendered role. Outside `work-ns`, a resource wildcard inside a named group is allowed only
for the Knative controllers' reads of their own API groups.

Under `singleNamespace: true` the release namespace is the work namespace. `work-ns` is a
Role bound there, so the wildcard covers Union's own objects: any component bound to it can
read Union's Secrets and change its Deployments. That blast radius is the accepted cost of
running in one namespace. If the components that launch tasks must be kept away from Union's
own Secrets and Deployments, use `singleNamespace: false`.

## Release-namespace grants do not come from `work-ns`

At `singleNamespace: false` the release namespace is not a work namespace and `work-ns` is
not bound there. Every call a component makes into the release namespace therefore needs its
own `comp-ns-read` or `comp-ns-write` rule. Without one, a call succeeds only by accident,
through the proxy's Secret Role, when every component shares `union-system` with the proxy.
With per-component ServiceAccounts, or a secret manager other than `K8s`, the call is denied.
So each component declares the calls it makes:

| Role | Grant | Granted when | Code path |
|---|---|---|---|
| `union-operator-comp-ns-read` | `apps` `deployments`, `daemonsets`, `statefulsets` `get,list,watch` | always | the cluster health snapshot, which reports every Union workload in the release namespace |
| `union-operator-comp-ns-read` | `configmaps`, `podtemplates` `get` | always | the cluster health snapshot's component config hashes and the propeller shard pod template, both read by name |
| `union-proxy-comp-ns-read` | `configmaps` `get` | always | the ClusterConfig service, which reads the same component ConfigMaps by name |
| `union-operator-comp-ns-read` | `configmaps` `get,list,watch` on `union-operator`; `secrets` `list,watch` | `imageBuilder.enabled` | the image builder's reference-ConfigMap informer and mirror-secrets deleter, both of which startup waits on |
| `union-operator-comp-ns-write` | `secrets` `get,update` on `operator.secretName` | `operator.enableTunnelService` | the tunnel token Secret |
| `union-operator-comp-ns-write` | `secrets` `create`; `get,update` on the API key state Secret | `config.operator.apiKey.enabled` | the Eager API key cache |
| `union-operator-comp-ns-write` | `configmaps` `update` on `connector-config` | `apps.enabled` | the apps controllers' connector registry |
| `union-webhook-comp-ns-read`, `-comp-ns-write` | `pods` `get`; `replicasets/finalizers` `update` | `singleNamespace: false` and `flytepropellerwebhook.managedConfig: false` | registering the MutatingWebhookConfiguration with the pod's ownerReferences |
| `union-webhook-comp-ns-write` | `secrets` `create`; `get,update` on the certificate Secret | `flytepropellerwebhook.certificate.provider: legacy` | the `init-certs` init container |
| `<release-ns>-secret-read` in `proxy.secretsNamespace` | `secrets` `get` | the webhook's secret manager type is `K8s`, except under `singleNamespace` with the secrets in the release namespace | the webhook's secret injection and the leaseworker connector plugin's secret reads |

Under `singleNamespace: true` these overlap with `work-ns`, which is bound in the release
namespace there. The chart emits them anyway, except the two whose code path only runs
outside that mode. This keeps a component's release-namespace access from depending on
another component's wildcard.

## Where a `secrets` rule belongs

A cluster slot is a `ClusterRole` plus a `ClusterRoleBinding`, so a `secrets` rule there
reads every Secret in every namespace on the cluster, tenant namespaces included. It is the
broadest grant this chart can express. Declare one only when the component's read is a
namespace-less `LIST` from an unscoped informer, which the API server authorizes at cluster
scope or not at all.

A namespace unknown at render time is no reason to use a cluster slot. `work-ns` exists for
that case: a `ClusterRole` bound per namespace authorizes an ordinary namespaced `Get` in a
namespace created long after Helm ran. What matters is how the read is made. Before this
change, `knative-controller`'s image-digest reads sat in `cluster-read` for the "unknown
namespace" reason. They are now in `work-ns`, with the same reach.

One component holds a cluster-wide `secrets` rule that cannot be narrowed today:

| Component | Why | Goes away when |
|---|---|---|
| `webhook` | The pod webhook's controller-runtime Secret cache is scoped only when propeller's `limit-namespace` is set to something other than `all`. The webhook reads the same config key propeller does, so scoping the cache would also pin propeller's own cluster-wide informer. Scoping it would break the mirroring the webhook exists for, because the secret manager reads the mirrored Secret from the admitted pod's own namespace through that cache | `config.core.webhook.embeddedSecretManagerConfig.imagePullSecrets.enabled: false` drops it today, along with the mirroring |

`knative-kourier` holds no cluster-wide `secrets` rule. The net-kourier image gates its
Secret informer behind `ENABLE_INGRESS_TLS`, which defaults to false and registers no Secret
informer while off. Earlier images registered it unconditionally and unfiltered by namespace,
which made the cluster-scoped `LIST` necessary. Setting that env var on
`net-kourier-controller` brings the informer back and requires the grant, and this chart
leaves it unset.

## Two RBAC subtleties

Both have produced defects in this chart.

**Subresources.** A subresource must be named in its own right. Granting `endpoints` does
not convey `endpoints/restricted`. On OpenShift, writing an Endpoints object that names a
pod IP requires `create` on `endpoints/restricted`, so a rule that looks complete fails at
runtime. The same applies to every `<resource>/status` and `<resource>/finalizers`.

**`resourceNames`.** It applies across the cartesian product of a rule's resources. A single
rule naming two resource kinds and three names claims all six kind/name pairs. So a rule like

```yaml
- apiGroups: [admissionregistration.k8s.io]
  resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations]
  resourceNames: [a, b, c]
```

That rule claims more than it appears to. Split it into one rule per resource when the names
differ by kind. Every Union-authored rule in this chart that sets `resourceNames` names a
single resource. You can check that property of any render with one pass over its `Role`
and `ClusterRole` documents.
