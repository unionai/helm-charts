# Dataplane RBAC

These pages describe what the dataplane chart grants, to which identity, and where:

- [scope.md](scope.md) covers what each scope mode grants, the cluster-scoped reads
  single-namespace mode keeps, and the cluster reads multi-namespace mode adds.
- [slots.md](slots.md) covers how Union's own components declare their grants, and how the
  chart turns those declarations into roles.
- [work-namespaces.md](work-namespaces.md) covers the work-namespace RoleBinding, what
  creates it, and how to confirm it landed.
- [cluster-writes.md](cluster-writes.md) lists every cluster-scoped write a Union identity can
  hold.
- [identities.md](identities.md) covers shared and per-component ServiceAccounts.
- [subcharts.md](subcharts.md) covers the third-party subcharts' RBAC.
- [app-serving.md](app-serving.md) covers the Knative stack, whose cluster-wide reads
  `singleNamespace` cannot narrow.

## Three independent keys

Three values keys are easy to confuse. Each answers a different question.

| Key | Default | Question it answers |
|---|---|---|
| `singleNamespace` | `true` | Does Union run in one namespace or many? |
| `namespaces.enabled` / `namespaces.static` | `false` / a six-name list | Which work namespaces exist at install time? |
| `commonServiceAccount.enabled` | `true` | How many identities hold the grants? |

**`singleNamespace`** is the only scope axis. It alone decides whether a component's grant
is a namespaced `Role` or a `ClusterRole`. At the `true` default every Union workload runs in
the release namespace. No route creates work namespaces, `namespaces` is ignored, and
`clusterresourcesync` is not rendered. The cluster-scoped reads that remain are a fixed
allowlist, enforced by `tests/test-rbac-guards.sh` and listed in
[scope.md](scope.md#what-singlenamespace-still-reads-cluster-wide). `low_privilege` is the
key's older name and still works as an alias. The chart refuses to render if both are set and
disagree.

**`namespaces.enabled`** pre-seeds namespaces. At `singleNamespace: false` it creates only
the Namespace objects named in `namespaces.static` and a work-namespace RoleBinding in each.
The role rules stay as they are, but those bindings make the `work-ns` grant effective in
each listed namespace, so the key decides where that grant lands. `singleNamespace: true`
ignores it, render checks included. [work-namespaces.md](work-namespaces.md) covers the
routes that create work namespaces.

**`commonServiceAccount.enabled`** shares identity and changes no rule. The chart emits the
same set of roles either way, but which workload can exercise which role differs. See
[Identities](identities.md).

Write these as unquoted YAML booleans. A quoted `"false"` is a non-empty string and reads
as true.
