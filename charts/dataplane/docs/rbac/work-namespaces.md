# Work-namespace bindings

At `singleNamespace: false`, Union reaches each work namespace through a RoleBinding named
`<release-ns>-work-ns`, which points at the ClusterRole of the same name. At
`singleNamespace: true` the chart binds that role in the release namespace itself, and
nothing on this page applies.

## Who creates the work-namespace binding

| Route | Turn it on with | What it covers |
|---|---|---|
| This chart | `namespaces.enabled: true` and `namespaces.static` | the namespaces listed, at install |
| `clusterresourcesync` | `clusterresourcesync.enabled: true` | each namespace, as its project is registered |
| Your own tooling | n/a | whatever it provisions |

Both chart routes are off by default. Turn one on in the same change that sets
`singleNamespace: false`. Otherwise the install renders cleanly and the first task fails with
`Forbidden`. You can combine routes, because they all write the same binding.

- **A static namespace gets only the Namespace and the binding.**
  `clusterresourcesync`'s templates also add three things, which you must supply yourself:
  - the workload-identity annotation on the `default` ServiceAccount
  - the `project-quota` ResourceQuota
  - the `union.ai/namespace-type: flyte` label. Without it, the operator doesn't copy
    `build-image-config` into the namespace. Set it with `namespaces.labels`.
- **Whatever creates the binding needs `bind`** on the `<release-ns>-work-ns` ClusterRole,
  because Kubernetes lets a caller grant only what it holds. The chart gives
  `clusterresourcesync` that `bind`, pinned by name, so it can hand the role out without
  holding the role's permissions.
- **If your own tooling creates the binding, copy the subjects** from a chart render, such as
  `helm template --set namespaces.enabled=true`. Don't compose them by hand. The list changes
  with what is enabled, and any extra subject receives the entire pooled role.

## Confirm the binding landed

A render can't show whether the binding landed, and neither can a healthy GitOps sync. After
you register a project, check:

```bash
kubectl get rolebinding <release-ns>-work-ns -n <work-ns> -o jsonpath='{.subjects[*].name}'
kubectl auth can-i create pods -n <work-ns> \
  --as=system:serviceaccount:<release-ns>:<one of those subjects>
```

If the binding is missing, look in `clusterresourcesync`'s logs for errors applying
`ab_work_ns_binding.yaml`.

A missing binding shows up in one of two ways:

- Task pods fail with `Forbidden`.
- Task pods using private images fail with `ImagePullBackOff`. The pod webhook couldn't mirror
  the pull secret into the namespace, so it logged the error and admitted the pod without the
  secret. The error appears only in `kubectl logs -n <release-ns> deploy/union-pod-webhook`.

## The `clusterresourcesync` risk

`clusterresourcesync` can write RoleBindings in any namespace, because RBAC cannot limit a
write to a set of namespaces. The `bind` pin limits which role it can grant, but not where.
A compromised `clusterresourcesync` could therefore bind `<release-ns>-work-ns` in any
namespace, `kube-system` included. That would give Union's accounts `pods: create` there,
and through it the permissions of every ServiceAccount in that namespace.

With `commonServiceAccount.enabled: true`, the default, `clusterresourcesync` runs on the
common account, so every component on that account holds this RoleBinding write too. Set
`commonServiceAccount.enabled: false` to keep it on its own `union-clustersync-system`
account.

This is the accepted cost of provisioning namespaces at runtime. You have two ways to manage
it:

- **Remove it.** Turn `clusterresourcesync` off and provision namespaces with tooling you
  trust.
- **Bound it.** Add an admission policy, such as Kyverno or Gatekeeper, that limits
  `clusterresourcesync`'s Namespace and RoleBinding writes to your project-namespace naming
  convention. The policy matches on the account `clusterresourcesync` runs as, so on the
  common account it bounds every component on it.
