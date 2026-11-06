# The cluster-scoped write surface

Most of what this chart grants is namespaced. The table lists the cluster-scoped,
state-mutating grants that Union identities hold. Their conditions are compatible, so a
multi-namespace zero-trust install with `clusterresourcesync`, `nodeobserver`,
`nodeBootstrap` and an unmanaged pod-webhook config renders all six at once. Treat the table
as the maximum surface.

| ClusterRole | Rendered when | Grant |
|---|---|---|
| `flyte-webhook-cleanup-<release-ns>` | always (upgrade hook) | `get`/`delete` on one named `MutatingWebhookConfiguration` |
| `union-clusterresourcesync-cluster-write` | `singleNamespace: false` + `clusterresourcesync.enabled` | get/create/patch on `namespaces`, `serviceaccounts`, `resourcequotas`, `rolebindings`; `bind` on `<release-ns>-work-ns` |
| `union-nodeobserver-cluster-write` | `nodeobserver.enabled` (either scope mode) | `update` on `nodes` |
| `union-node-bootstrap-cluster-write` | `nodeBootstrap.enabled` with `nodeBootstrap.startupTaintKey` set (either scope mode) | `update` on `nodes`, to remove the startup taint from its own node |
| `union-webhook-cluster-write` | `singleNamespace: false` + `flytepropellerwebhook.managedConfig: false` | `create` on `mutatingwebhookconfigurations`; `get`/`update` on the one it registers, named by `config.core.webhook.serviceName` |
| `union-knative-webhook-cluster-write` | app serving under zero trust | `update` on three named webhook configurations, plus `namespaces/finalizers` on the release namespace |

The `clusterresourcesync` row is the irreducible one. It applies ServiceAccounts and
ResourceQuotas into a namespace on the sync that creates it, before any RoleBinding exists
there, so those rules cannot be namespaced. The controller applies with a create and, when
the object already exists, a get and a patch, so the rules carry exactly those verbs. Its
`namespaces` rule gains `delete` only under
`clusterresourcesync.config.cluster_resources.unionProjectSyncConfig.cleanupNamespace: true`.

The pod webhook's row is as narrow as its registration call allows. It creates its
MutatingWebhookConfiguration and, if one already exists, gets and updates it, and those are
its only verbs. `get` and `update` are pinned by `resourceNames` to the name it registers
under. `create` cannot be pinned, since the name does not exist before the object does.

The `clusterresourcesync` row allows more than its pin suggests. Its `rolebindings` write is
cluster-wide, because RBAC cannot confine a namespaced write to a subset of namespaces, and
`<release-ns>-work-ns` is a resource-wildcard role. A compromised `clusterresourcesync` could
therefore plant a `<release-ns>-work-ns` RoleBinding in a namespace this release does not
own, giving Union's ServiceAccounts admin over it. The `bind` pin limits which role it can
grant directly and says nothing about where that grant leads. No stronger role can be
substituted, and `namespaces` `delete` stays off unless `cleanupNamespace` is on, so it
cannot destroy a tenant namespace. But `<release-ns>-work-ns` carries `pods: create`, and
creating a pod in a namespace conveys the permissions of every ServiceAccount already in it.
Suppose it is bound into a namespace that holds a stronger identity, such as `kube-system`
on a stock cluster. Then the role gives a route past the limit the pin appears to set.

This is the accepted cost of provisioning namespaces at runtime. You can remove it or bound
it:

- **Remove it.** Turn `clusterresourcesync` off and provision namespaces and map projects
  with something you trust.
  - Pre-seeding with `namespaces.enabled: true` and `namespaces.static` does not replace
    `clusterresourcesync`.
  - The list is fixed at install, so projects registered later need that tooling, and a
    static namespace gets only its Namespace and RoleBinding.
- **Bound it.** Keep `clusterresourcesync` and use an admission policy, such as Kyverno or
  OPA/Gatekeeper, that restricts its RoleBinding and Namespace writes to your
  project-namespace naming convention. Only an admission policy can constrain the shape of
  what it creates, and re-cutting the RBAC cannot.

That row is also the one you can extend. `clusterresourcesync.clusterRoleRules` is the escape
hatch for resource types that your own `templates` or `additionalTemplates` entries create.
Anything set there is appended to that same ClusterRole, cluster-wide, and the allowlist it
passes through permits `create`, `update`, `patch`, `delete` and `deletecollection`. The
allowlist refuses a wildcard verb and an all-groups `apiGroups: ["*"]`, but accepts a
resource wildcard inside a named group. So `apiGroups: [""], resources: ["*"], verbs: [get]`
renders and reads every core resource, Secrets included. Audit that key alongside this
table.

Beyond this table and that key, every cluster-scoped grant held by a Union identity is
read-only. `clusterresourcesync` holds no `system:auth-delegator` binding, because the
controller serves only unauthenticated metrics and pprof and makes no TokenReview or
SubjectAccessReview.

Under `singleNamespace: true` only three rows of this table can render. The upgrade hook's
is pinned to one name. The other two, nodeobserver's and node-bootstrap's, are the unpinned
cluster-scoped writes the mode allows, and RBAC cannot pin either to the node the pod runs
on. `tests/test-rbac-guards.sh` asserts that set.

`singleNamespace` is not a whole-chart namespace boundary, and a namespace-confined install
identity is not enough to deploy this chart. See [scope.md](scope.md#singlenamespace-is-not-a-whole-chart-namespace-boundary).
