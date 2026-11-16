# Dataplane RBAC

- [slots.md](slots.md) describes the slot system that grants Union's own components their
  permissions.
- [work-namespaces.md](work-namespaces.md) covers the RoleBinding every work namespace needs
  under `singleNamespace: false`.

What a given component is granted lives in code. [Where to look](#where-to-look) points to it.

## Three keys

| Key | Default | Decides |
|---|---|---|
| `singleNamespace` | `true` | Whether Union runs in the release namespace, or in a namespace per project and domain. This is the only scope axis. |
| `namespaces.enabled`, `namespaces.static` | `false` | Which work namespaces the chart creates and binds at install. Ignored at `singleNamespace: true`. |
| `commonServiceAccount.enabled` | `true` | Whether components share the `union-system` account or each get their own. This changes which identity holds a rule, not the rules themselves. |

`low_privilege` is the older name for `singleNamespace` and still works. The render fails if
both are set and disagree. Write these keys as unquoted booleans.

## What `singleNamespace: true` promises

- Union's workloads, tasks and apps included, run in the release namespace. Every grant
  that can be namespaced is namespaced.
- Cluster-scoped reads come only from a fixed allowlist of reads that have no namespaced
  form: nodes, node and API server metrics, IngressClass, and Knative's informers.
- Cluster-scoped writes are pinned to named objects. nodeobserver and node-bootstrap are the
  exceptions, and both are off by default. Each removes a startup taint from its own node.

The mode does not make the whole chart namespace-bound. Third-party subcharts keep their own
cluster RBAC, and the uvol mount broker creates a PriorityClass and a CSIDriver. An install
identity confined to one namespace cannot deploy this chart.

## Caveats

- **App serving reads cluster-wide.** It is on by default in both modes, and Knative's
  binaries watch every namespace regardless of how their RBAC is written. To hold an install
  to the allowlist, set `apps.enabled: false`.
- **Split identities need cloud bindings first.** At `commonServiceAccount.enabled: false`,
  each new account needs a workload-identity binding before it can reach cloud storage. That
  is an IRSA trust subject on AWS, a Workload Identity member on GCP, or a federated
  credential on Azure. Without one, the pods keep running and their storage calls fail.
- **fluentbit runs as `union-system`** unless you set `fluentbit.serviceAccount.name`. Under
  the shared account it holds every grant bound to `union-system`, including `work-ns`, on
  every node. Under split identities, nothing is bound to `union-system`.
- **CRD task plugins need `taskPluginClusterReadRules`** at `singleNamespace: false`. See its
  comment in `values.yaml`.

## Where to look

| Question | Answer |
|---|---|
| What does component `x` get, and under which values? | `dataplane.rbac.slots.x`, in `templates/x/serviceaccount.yaml`. Knative's declarations are in `templates/gateway/serviceaccounts.yaml`. |
| Which components get slot roles, and under which accounts? | `dataplane.rbac.components` in `templates/_rbac.tpl` |
| What may single-namespace mode read cluster-wide? | `SCOPE_ALLOWLIST` in `tests/test-rbac-guards.sh` |
| What do Prometheus and kube-state-metrics get? | `templates/prometheus/rbac.yaml`. `templates/prometheus/validate.yaml` refuses the subchart options it cannot grant. |
| What do the other subcharts get? | Their own templates, and the comments beside their keys in `values.yaml` |

## Auditing

Audit the rendered roles, not the declarations. Rendered roles show what `work-ns` pooling
adds (see [slots.md](slots.md#work-ns-is-pooled)).

At `singleNamespace: false` the default render has no work namespaces, so `<release-ns>-work-ns`
is unbound. An audit that walks bindings would report everything in that role as lost. Render
with `--set namespaces.enabled=true`, or audit a live cluster after the first sync.

Key each permission on (ServiceAccount, namespace, apiGroup, resource, verb). Keep the
namespace column, because a grant in a work namespace does not stand in for one missing in
the release namespace.
