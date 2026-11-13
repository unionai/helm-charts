# The slot system

Each Union component declares its rules into slots, and the chart emits a role and a binding
for each slot. A slot is named for where its rules apply:

- the **release namespace**, which holds Union's own Deployments, Secrets and ConfigMaps
- the **work namespaces**, one per project and domain, which hold tasks, apps and image builds
- the **cluster**, for objects that have no namespace

## The six slots

| Slot | Applies in | Emitted as | Verbs | Roles | At `singleNamespace: true` |
|---|---|---|---|---|---|
| `comp-ns-read` | release ns | Role, RoleBinding | read | one per component | unchanged |
| `comp-ns-write` | release ns | Role, RoleBinding | write | one per component | unchanged |
| `work-ns` | each work ns | ClusterRole, a RoleBinding per work ns | write | **one, pooled** | a Role bound in the release ns |
| `work-ns-cluster-read` | every ns | ClusterRole, ClusterRoleBinding | read | one per component | not emitted |
| `cluster-read` | cluster | ClusterRole, ClusterRoleBinding | read | one per component | unchanged |
| `cluster-write` | cluster | ClusterRole, ClusterRoleBinding | write | one per component | unchanged |

Read means `get`, `list` and `watch`. Write adds `create`, `update`, `patch`, `delete` and
`deletecollection`. These are upper bounds. Each rule names only the verbs its component
actually calls.

Roles are named `<release-ns>-<component>-<slot>`, for example `union-operator-comp-ns-read`.
The pooled role has no component in its name: `<release-ns>-work-ns`.

## Declaring a component

1. Add the component and its ServiceAccount to `dataplane.rbac.components` in
   `templates/_rbac.tpl`.
2. Define `dataplane.rbac.slots.<name>`, usually in the component's `serviceaccount.yaml`.
   It returns a map from slot name to rules:

```yaml
{{- define "dataplane.rbac.slots.example" -}}
comp-ns-read:
  # Reads its own config by name at startup.
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [example-config]
    verbs: [get]
work-ns:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, create, delete]
{{- end -}}
```

Gate each rule on the values that turn on the code path that uses it, not just on the
component being enabled. If the reason for a rule isn't obvious from the resource, put a
one-line comment above it.

`dataplane.rbac.emitSlot` fails the render if a rule:

- has no `verbs`, or names a verb the slot doesn't allow
- names `*`, `escalate`, `impersonate` or `bind` as a verb
- names `apiGroups: ['*']` in any slot but `work-ns`

`tests/test-rbac-guards.sh` adds checks on the rendered roles, including the single-namespace
allowlist.

## Choosing a slot

Pick the slot by how the API call is made, not by which namespace it targets.

- **A call into the release namespace** goes in `comp-ns-read` or `comp-ns-write`. This holds
  even under `singleNamespace: true`, where `work-ns` would also cover the call. A component's
  access to Union's own namespace should not depend on another component's wildcard.
- **A namespaced call into a work namespace** goes in `work-ns`. That includes a `get` in a
  namespace created long after install. Not knowing the namespace at render time is no reason
  to use a cluster slot.
- **A list or watch with an empty namespace** is authorized at cluster scope, and no number
  of RoleBindings satisfies it. Unscoped informers make this kind of call.
  - If the informer goes cluster-wide only because no limit namespace is set at
    `singleNamespace: false`, use `work-ns-cluster-read`. Also make sure the namespaced form
    is covered for single-namespace mode, usually by `work-ns`.
  - If the informer is cluster-wide in both modes, as Knative's are, use `cluster-read`.
- **A cluster-scoped object** such as `nodes` goes in `cluster-read` or `cluster-write`. Both
  slots survive `singleNamespace: true`. A read there must be on the single-namespace
  allowlist. A write must be pinned with `resourceNames`.

`secrets` in a cluster slot reads every Secret on the cluster, which is the broadest grant
this chart can express. Use it only for a namespace-less list that cannot be scoped, and
explain why beside the rule.

## `work-ns` is pooled

Every other slot emits one role per component. `work-ns` emits a single role that holds the
union of every declarer's rules, and binds it to every declarer's ServiceAccount. Pooling
buys two things:

- **One RoleBinding per work namespace.** A namespace that `clusterresourcesync` creates at
  runtime becomes reachable by every component through one object. It cannot end up
  reachable by some components and not others.
- **One `bind` grant.** `clusterresourcesync` holds `bind` on this one role, pinned by
  `resourceNames`.

The cost is that a `work-ns` declaration states what the component needs, not what it gets.
leaseworker and flytepropeller each declare `apiGroups: ['*'], resources: ['*']`, so every
`work-ns` declarer holds that wildcard, the read-only proxy included.

`work-ns` is a ClusterRole only so its rules are written once. Every binding to it is a
namespaced RoleBinding, which confines the role to that one namespace.

## The wildcard is not the boundary

A component that can create pods in a namespace already has full control there. The pod can
run as any ServiceAccount in the namespace and mount any Secret. Union creates task pods in
every work namespace, so narrowing `work-ns` would make it harder to read and no safer.

The boundary is where `work-ns` is bound:

- At `singleNamespace: false` it is bound only in work namespaces. The release namespace
  never gets the binding, and the chart refuses a `namespaces.static` that lists the release
  namespace.
- At `singleNamespace: true` the release namespace is the work namespace, so the wildcard
  covers Union's own Secrets and Deployments. Single-namespace mode accepts that. If the
  components that launch tasks must not reach those objects, use `singleNamespace: false`.

A binding limits only its own role. An identity can also hold release-namespace grants from
other roles, such as the proxy's Secret Role. To learn what an identity can do, list every
binding that names it.

## Grants outside the slots

Some roles are written directly, not through the emitter:

- roles in a namespace you name, such as the Secret Roles in `proxy.secretsNamespace` and the
  operator's secrets-watcher Role
- Helm hooks, such as the pre-upgrade cleanup of the legacy pod webhook
- verbs that no slot allows, such as `use` on a named SecurityContextConstraints
- the `bind` rule on `<release-ns>-work-ns`, which the emitter appends to
  `clusterresourcesync`'s `cluster-write`
- subchart RBAC, including the chart's own Prometheus and kube-state-metrics rules in
  `templates/prometheus/rbac.yaml`

To list them, render the chart and set aside every role named `<release-ns>-<component>-<slot>`
or `<release-ns>-work-ns`.

## RBAC gotchas

Each of these has caused a defect in this chart.

- **Subresources are separate resources.** Granting `endpoints` does not grant
  `endpoints/restricted`, and the same holds for `/status` and `/finalizers`. Name each
  subresource you need.
- **`resourceNames` applies to every resource in the rule.** A rule with two resources and
  three names grants all six combinations. When the names differ by resource, write one rule
  per resource.
- **A Role cannot grant a cluster-scoped resource.** Naming `nodes` in a namespaced Role is
  legal but matches nothing. That is how the cadvisor scrape returned 403 for three months.
