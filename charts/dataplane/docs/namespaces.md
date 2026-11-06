# Namespaces

This page covers which namespaces a dataplane runs Union's work in, what creates them, and
what each one needs before a task can run there. For the roles bound in those namespaces, see
[rbac-union.md](rbac-union.md).

## Scope decides whether there are work namespaces

`singleNamespace` is the only key that sets the scope. `low_privilege` is its older name
and still works. With neither key set, the install is single-namespace. Both keys must be
unquoted YAML booleans. The render fails on a quoted string, and on the two keys set to
different values.

| | `singleNamespace: true` (default) | `singleNamespace: false` |
|---|---|---|
| Where tasks and apps run | the release namespace | the work namespaces that `namespace_mapping` names |
| `namespace_mapping` | pinned to the release namespace | used as set |
| `namespaces.*` | ignored, including its render checks | creates the namespaces in `namespaces.static` when `namespaces.enabled: true` |
| `clusterresourcesync` | not rendered, whatever `enabled` says | rendered when `enabled: true` |

In single-namespace mode the release namespace is the work namespace, and the chart binds
the `work-ns` role, named `<release-ns>-work-ns`, there itself. The rest of this document applies to
`singleNamespace: false`.

## How work namespaces are named

`namespace_mapping.template` names the namespace a run lands in. The operator, the
leaseworker, flytepropeller and `clusterresourcesync` all read it, so they agree. Unset,
each falls back to `{{ project }}-{{ domain }}`, which is one namespace per project and
domain.

`values.gcp.yaml` and `values.azure.yaml` set it to `{{ domain }}`, which gives three
namespaces shared by every project, named `development`, `staging` and `production`.
Workload identity on those clouds binds each Kubernetes ServiceAccount by namespace and has
no wildcard, so the set of namespaces has to be bounded.

Whatever creates work namespaces has to produce exactly these names, and the chart does
not check that it does. A task mapped to a namespace that is missing, or that lacks its
binding, fails when it runs while the render succeeds.

## What a work namespace needs

| Object | Why | `clusterresourcesync` | `namespaces.static` |
|---|---|---|---|
| the Namespace | | `a_namespace` template | yes |
| label `union.ai/namespace-type: flyte` | the operator copies the image builder's `build-image-config` ConfigMap only into namespaces carrying it | `a_namespace` template | only if you set it in `namespaces.labels` |
| RoleBinding `<release-ns>-work-ns` | gives Union's components the `work-ns` role in that namespace | `ab_work_ns_binding.yaml`, which the chart adds | yes |
| `default` ServiceAccount annotated with `userRoleAnnotationKey: userRoleAnnotationValue` | maps the account tasks run as to a cloud identity: an IAM role on AWS, a service account on GCP, a managed identity on Azure | `b_default_service_account` template | no |
| ResourceQuota `project-quota` | per-namespace CPU, memory and GPU limits | `c_project_resource_quota` template | no |

Anything in `clusterresourcesync.additionalTemplates` is applied as well, by that route
only.

`namespaces.static` creates the Namespace and its RoleBinding only. Where tasks reach
object storage through workload identity, a static namespace that `clusterresourcesync`
does not also provision is reachable by Union. Its tasks cannot read or write storage
until you annotate its `default` ServiceAccount yourself. Set `namespaces.labels` to
`union.ai/namespace-type: flyte` if image builds run there.

## Three routes to create them

Each work namespace and its binding come from one of three routes. They can be combined,
and where two routes cover the same namespace they write the same RoleBinding.

| Route | Turned on by | Covers | Runs |
|---|---|---|---|
| `clusterresourcesync` | `clusterresourcesync.enabled: true` | every registered project | on each sync |
| this chart | `namespaces.enabled: true` | the names in `namespaces.static` only | at install and upgrade |
| your own tooling | leaving both keys `false` | whatever it creates | whenever it runs |

### `clusterresourcesync`

`clusterresourcesync` runs every `clusterresourcesync.config.cluster_resources.refreshInterval`,
5m by default. On each sync it creates the mapped namespace for every registered project and
domain. It then applies each template there in key order, which is the namespace, the `work-ns`
binding, the `default` ServiceAccount and the quota. A project registered after install is
reachable from its first sync. This is the usual choice, because it is the only route that
keeps up with new projects on its own.

The cost is a cluster-wide ClusterRole with `get`, `create` and `patch` on every kind its
templates create, plus `bind` on the `work-ns` role. It gets `delete` on namespaces only under
`cluster_resources.unionProjectSyncConfig.cleanupNamespace: true`.
[The cluster-scoped write surface](rbac-union.md#the-cluster-scoped-write-surface) covers
what that grant allows and how to bound it with an admission policy.

Add templates through `additionalTemplates`. Setting `templates` replaces the whole list,
and dropping `a_namespace`, `b_default_service_account` or `c_project_resource_quota`
drops that object from every namespace the sync creates.

### This chart: `namespaces.enabled` and `namespaces.static`

With `namespaces.enabled: true`, the chart creates a Namespace and a `<release-ns>-work-ns`
RoleBinding for each name in `namespaces.static`. The list is fixed when you install or
upgrade, so projects registered later need `clusterresourcesync` or your own tooling.

- **List the names `namespace_mapping` produces.** The default six,
  `flytesnacks-{development,staging,production}` and
  `union-health-monitoring-{development,staging,production}`, match only
  `{{ project }}-{{ domain }}`, and only for those two projects. Under `{{ domain }}` the
  chart creates six namespaces and bindings that sit idle, and the matching list is
  `[development, staging, production]`.
- **Do not list the release namespace.** The render fails, because binding the `work-ns`
  role there would give every Union component write access to Union's own Deployments and
  Secrets.
- **Do not leave the list empty.** `namespaces.enabled: true` with an empty
  `namespaces.static` fails the render.
- **Write `enabled` as an unquoted boolean.** `namespaces.enabled: "false"` is a non-empty
  string, reads as true, and creates every listed namespace.

### Your own tooling

Leave `namespaces.enabled` and `clusterresourcesync.enabled` at `false` and create, in each
work namespace, the objects in [What a work namespace needs](#what-a-work-namespace-needs).
Copy the RoleBinding from a chart render rather than writing it by hand, because its
subjects depend on `commonServiceAccount.enabled` and on which components are on. Render
with `--set namespaces.enabled=true` and take any `<release-ns>-work-ns` RoleBinding,
changing only its namespace. Whatever creates it needs `bind` on the `<release-ns>-work-ns`
ClusterRole, because Kubernetes lets a caller grant only permissions it holds itself.

## The defaults create nothing

`namespaces.enabled` and `clusterresourcesync.enabled` both default to `false`, so
`singleNamespace: false` on its own renders cleanly and deploys healthy, with no work
namespaces and no bindings. The first task then fails with `Forbidden` or `namespace not
found`, although the render and the deployment looked healthy. Choose a route in the same
change that sets `singleNamespace: false`.

After registering a project, confirm its namespaces are complete:

```bash
kubectl get namespace <work-namespace> --show-labels
kubectl get rolebinding <release-ns>-work-ns -n <work-namespace>
kubectl get serviceaccount default -n <work-namespace> -o jsonpath='{.metadata.annotations}'
```

[rbac-union.md](rbac-union.md#the-union-work-ns-clusterrole-can-render-present-but-unbound)
shows how to check the binding's subjects and what they can do. A missing binding can also
cause task pods to fail with `ImagePullBackOff` on private images. See
[One failure that does not look like RBAC](rbac-union.md#one-failure-that-does-not-look-like-rbac).

## Labels, annotations and retention

`namespaces.labels` and `namespaces.annotations` apply to the namespaces in
`namespaces.static` only. Namespaces `clusterresourcesync` creates take their metadata from
its `a_namespace` template.

`namespaces.annotations` defaults to `helm.sh/resource-policy: keep`, so `helm uninstall`,
or dropping a name from the list, leaves the Namespace and everything in it. Only Helm
honors that key. A GitOps controller prunes a Namespace that leaves the manifest unless you
add its own retention key, such as `argocd.argoproj.io/sync-options:
Prune=false,Delete=false`. Set the key to `null` if your own tooling owns the namespaces'
lifecycle.

Helm reads the policy off the live object. A namespace created by a chart version that
did not set it therefore gets protection only after the upgrade that adds it. Upgrade once with the
list unchanged, then remove names. The
[release notes](../RELEASE.md#migration--action-required) give the details.

## What removing things leaves behind

| Change | Static namespaces | Chart-created RoleBindings | Objects `clusterresourcesync` created |
|---|---|---|---|
| drop a name from `namespaces.static` | that namespace stays | its binding is deleted, so Union loses access there | unchanged |
| `namespaces.enabled: false` | all stay | all deleted | unchanged |
| `helm uninstall` | all stay | all deleted | all stay, since Helm does not manage them |
| switch to `singleNamespace: true` | all stay | all deleted | all stay |

Single-namespace mode renders the `work-ns` role as a Role in the release namespace.
After the switch, the RoleBindings `clusterresourcesync` created point at a ClusterRole that
no longer exists. They have no effect until you switch back. Delete those RoleBindings, and
any work namespaces you no longer need.

## Changing scope on a live install

Tasks follow the new mapping on their next run. On GCP and Azure, add the cloud-side
workload-identity bindings for the new namespaces' `default` ServiceAccounts before you
switch, or tasks there cannot reach storage.

Deployed apps need a manual cleanup. When you switch from `singleNamespace: true` to
`false`, the operator re-creates each app's Knative Service in its work namespace. The copy
left in the release namespace keeps the app's domain, so the new copy sits at
`DomainConflict`. Deleting the old copy hangs. In multi-namespace mode neither the operator
nor Knative may write in the release namespace.
Neither can remove its finalizers, which are the
operator's `serving.unionai.dev/finalizer` on the Service and Knative's own on its Route
and Ingress. As a cluster admin, delete the old copy and clear all three:

```bash
ns=<release-ns>; app=<service-name>
kubectl delete ksvc "$app" -n "$ns" --wait=false
kubectl patch ksvc "$app" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl patch route "$app" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl patch ingresses.networking.internal.knative.dev "$app" -n "$ns" \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

The work-namespace copy then goes Ready on the same domain. Switching from `false` to
`true` is the mirror image. The work-namespace copies keep the domain, single-namespace
Knative cannot reach them, and they need the same cleanup in each work namespace.

## Upgrading from a chart where `namespaces.enabled` set the scope

Before this change the scope was `or (not namespaces.enabled) low_privilege`, so
`namespaces.enabled: false` meant single-namespace mode even with `low_privilege: false`.
Now either `low_privilege: false` or `singleNamespace: false` on its own means
multi-namespace.

An install running `low_privilege: false` with `namespaces.enabled: false` was
single-namespace. On upgrade it becomes multi-namespace, and nothing creates its work
namespaces. That is the state in [The defaults create nothing](#the-defaults-create-nothing),
and the render still succeeds. Before upgrading such an install, set `singleNamespace: true`
to keep it where it is, or choose a route and treat the upgrade as a scope change.

An install with `namespaces.enabled: true` and `low_privilege: false` was multi-namespace
already. On upgrade its static namespaces gain the `keep` annotation and a
`<release-ns>-work-ns` RoleBinding each.

The [release notes](../RELEASE.md#migration--action-required) list every other change
from the same rework.
