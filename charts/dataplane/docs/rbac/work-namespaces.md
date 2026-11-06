# Work-namespace bindings

Under `singleNamespace: false`, Union's components reach each work namespace through one
RoleBinding there. This page covers what creates it and how to confirm it landed. In
single-namespace mode the release namespace is the work namespace, and the chart binds the
`work-ns` role there itself.

## Who creates the work-namespace binding

Something must create a `RoleBinding` named `<release-ns>-work-ns` in each work namespace.
Three routes can do it, and they can be combined:

- **This chart**, when `namespaces.enabled: true` and `namespaces.static` is non-empty. It
  creates one RoleBinding per listed namespace at install.
- **`clusterresourcesync`**, when enabled. It creates each work namespace as a project is
  registered. The chart hands it the RoleBinding as an entry in its clusterresource-template
  ConfigMap, keyed `ab_work_ns_binding.yaml` so it is applied right after the Namespace.
- **Your own tooling**, if you provision work namespaces yourself.

`namespaces.enabled` and `clusterresourcesync.enabled` both default to `false`, so choose a
route in the same change that sets `singleNamespace: false`.
[The next section](#the-union-work-ns-clusterrole-can-render-present-but-unbound) covers
what happens otherwise.

`namespaces.static` is fixed at install, so projects registered later get their namespaces
only from `clusterresourcesync` or your own tooling. With `clusterresourcesync` enabled, the
chart emits its binding entry and `bind` grant whether or not `namespaces.enabled` is set.
Where two routes cover a namespace, they write the same RoleBinding.

A static namespace gets only its Namespace and RoleBinding. It lacks the workload-identity
annotation on its `default` ServiceAccount, the `project-quota` ResourceQuota and the
`union.ai/namespace-type: flyte` label that the `clusterresourcesync` templates add. Without
the label the operator does not copy `build-image-config` into it. Add those yourself, the
label through `namespaces.labels`.

Whatever creates the binding also needs `bind` on the `<release-ns>-work-ns` ClusterRole,
because Kubernetes lets a caller grant only permissions it holds itself. Creating the
RoleBinding fails without `bind` even when every other permission is in place. The chart
grants `clusterresourcesync` exactly that, pinned by `resourceNames` to the one role, so it
can bind that role alone and never holds the role's own permissions.

## The `union-work-ns` ClusterRole can render present but unbound

At `singleNamespace: false` with `namespaces.enabled: false`, the default multi-namespace
posture, the `union-work-ns` ClusterRole renders with no binding at all. That is expected
when `clusterresourcesync` or your own tooling creates the binding at runtime.
`clusterresourcesync` creates the per-namespace RoleBindings as it provisions each namespace,
and a `helm template` run cannot show an object that does not exist yet.

It is a defect when no route is in play. `clusterresourcesync.enabled` also defaults to
`false`, so `singleNamespace: false` alone, with `namespaces.enabled` left at `false` and
no external provisioner, renders the same unbound ClusterRole and never binds it. That
render is indistinguishable from the healthy one, which is why the check below runs on the
cluster and not on the manifest.

A render cannot show whether the binding landed. The install renders green and a GitOps
controller reports healthy. The first sign of trouble is a task execution failing with
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

The binding's subjects are exactly the accounts that declare into the `work-ns` slot.
Which accounts those are depends on what is enabled: four under split identities with apps off, seven
with zero-trust app serving. Do not compose the list by hand. Copy it from a chart-rendered
binding, either from `helm template --set namespaces.enabled=true` or from the
`ab_work_ns_binding.yaml` entry in `clusterresourcesync`'s ConfigMap. An account that does not
declare into the slot but is added to the binding receives the pooled role's full write set
in every work namespace. That includes `clusterresourcesync`, which holds `bind` on this role
precisely so that it can hand the role out without holding it.

## Auditing the pooled role

A capability audit of this chart is valid only where the pooled slot is bound. An audit that
walks bindings reports the entire contents of `union-work-ns` as lost when it runs against a
render where that role is unbound. That is the default multi-namespace render. That looks
like a serious regression but is a measurement artifact. Audit against a posture with the
bindings present, either `--set namespaces.enabled=true` or a live cluster after the first
sync. Key capability tuples on `(serviceaccount, scope, apiGroup, resource, verb)` and keep
the scope column, because a grant held in a work namespace does not substitute for one
missing in the release namespace.

## One failure that does not look like RBAC

If task pods fail with `ImagePullBackOff` or `ErrImagePull` on images from a private
registry, suspect a missing work-namespace binding before suspecting the registry.

The pod webhook mirrors image-pull secrets into each work namespace. If the mirror is
forbidden, the webhook swallows the `Forbidden` and admits the pod without its secret. The
failure surfaces at image pull, and the pod's events show only the pull error. The only trace
is in the webhook's own log:

```bash
kubectl logs -n <release-ns> deploy/union-pod-webhook
```

Each of these renders green and still produces this failure:

- `clusterresourcesync` enabled but crash-looping or not yet past its first sync
- your own tooling broken or lagging
- `namespaces.static` missing the namespace the task landed in

Confirm the binding exists in the affected namespace before looking anywhere else.
