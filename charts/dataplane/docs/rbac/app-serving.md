# App serving

When `apps.enabled` is unset it is on in either mode, so the default install, which is
single-namespace, runs app serving. Under `singleNamespace: true` that brings in the Knative
stack's cluster-wide reads described below. They are the one exception to single-namespace
mode's fixed list of cluster-scoped grants. To hold the install to that list, set
`apps.enabled: false` or the deprecated `serving.enabled: false`.

The recommended way to run app serving is multi-namespace. Layer this over the zero-trust
default:

```yaml
# singleNamespace: false alone turns app serving on; apps.enabled: true states it.
apps:
  enabled: true
# low_privilege is the older name for this key. If another values file you layer
# sets low_privilege: true, the render fails ("singleNamespace is false but
# low_privilege is true") rather than let one file silently flip scope. Use one
# name in every file, preferably singleNamespace; see charts/MIGRATION.md.
singleNamespace: false

# singleNamespace: false runs one namespace per project/domain, so something has
# to create them as projects are registered. clusterresourcesync is that
# something, and it defaults to off. Drop this block only if you provision those
# namespaces yourself; task pods fail with Forbidden or "namespace not found"
# otherwise.
clusterresourcesync:
  enabled: true
```

Under `singleNamespace: true` with app serving on, the Knative workloads keep their
`cluster-read` ClusterRoles and the webhook its name-pinned `cluster-write`. At the same
time, the `work-ns` grant, `<ns>-work-ns`, becomes a Role in the release namespace, where the apps
run. The vendored Knative stack renders whenever app serving is on and this chart delivers
it. The deprecated `knative-operator` path, which applies when `gateway.enabled` is false, is
out of scope here.

The `apps.enabled` default lives in the helper's final branch, and `values.yaml` leaves the
key null. Writing
`apps.enabled: false` in `values.yaml` would make the key set, and precedence is
`apps.enabled > serving.enabled > not singleNamespace`, so the deprecated `serving.enabled`
would stop being consulted. Every install still using it would lose app serving while asking
for it. `tests/values/dataplane.aws.zero-trust-serving-enabled.yaml` is the golden that
catches that.

App serving is the one component `singleNamespace` cannot narrow. Its RBAC is declared per
binary through this chart's slot framework, like every other component's, and every grant
that can be namespaced is. The remaining cluster-wide reads come from what the images do.

The watches are unscoped. The deployments take only `SYSTEM_NAMESPACE`, where Knative's own
config lives. Upstream ships no namespace-scoped install, and the binaries take the shared,
unfiltered informers from `knative.dev/pkg` without scoping them to a namespace. Those reads
go out with an empty namespace, which Kubernetes authorizes as a cluster-scope check.

Each binary holds a subset. The webhook watches only the two webhook-configuration kinds,
the activator watches Services, Endpoints and Revisions, the autoscaler adds Pods,
Deployments, leases and HPAs, and `net-kourier` adds Ingresses. Every one of those subsets is
cluster-scoped. A namespaced Role would authorize none of it, so the controller, webhook and
activator would report Ready while every read is denied. The prometheus and
kube-state-metrics guards prevent the same failure, but no values key exists to guard on
here.

So app serving reads every namespace in the cluster. `singleNamespace: true` promises that
Union's cluster-scoped reads are a fixed list. Knative's reads are on that list whenever app
serving is on, which is the default in both modes. The scope allowlist in
`tests/test-rbac-guards.sh` names them under that condition. Set `apps.enabled: false` to
drop them. The webhook configurations confirm this from the other direction: every rule has
`scope: "*"` and omits `namespaceSelector`, so admission intercepts cluster-wide regardless
of RBAC. `singleNamespace` changes nothing here, because the default and the Knative grants
are the same in both modes. The release notes give the per-component breakdown.

The stack renders only as a whole. Rendering `apps.enabled: true` without the stack
would leave the operator advertising app serving and holding its namespaced
`serving.knative.dev` grant. Every Knative Service it created would sit unreconciled, and
nothing would report why. So `apps.enabled` means one thing in both modes, and the operator's
config and Role stay consistent with it.

The Envoy gateway, dataproxy and tunnel-service ingress gate on `serving.renderGateway`,
which is `gateway.enabled` with either app serving or zero trust. Under zero trust they
therefore still render with `apps.enabled: false`. They hold no cluster-scoped RBAC, and
their static dataplane routes are what zero trust consists of. Turning app serving off
leaves zero trust intact.

The fixtures `tests/values/dataplane.aws.zero-trust{,-overrides,-serving-enabled}.yaml` turn
app serving on, so they pin `low_privilege: false`, the older name of the scope key. The
`-apps-disabled` fixture leaves scope at the default, which lets it prove that `apps.enabled`
beats `serving.enabled`. A regression that read `serving.enabled` as true would render the
Knative stack into that golden. `tests/test-rbac-guards.sh` asserts the default and the
opt-in under `singleNamespace`.
