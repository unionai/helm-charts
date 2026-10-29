# Third-party subchart RBAC

What each dependency subchart is allowed to read, and why. [App serving](#app-serving) is
here too: it is not a subchart, but it is the one component whose cluster-wide reads the flag
cannot narrow, so the flag turns it off by default instead.

For Union's own components — the slot model, the work-namespace bindings and the identity
axis — see [rbac-union.md](rbac-union.md). Two points about them are covered here because
they decide what either scope mode is worth: [the work-ns
wildcard](#the-work-ns-wildcard) and [plugin CRD reads at `singleNamespace:
false`](#plugin-crd-reads-at-singlenamespace-false).

## The work-ns wildcard

The pooled `<release-ns>-work-ns` role grants `apiGroups: ['*']`, `resources: ['*']` with
every verb except `deletecollection`. That is deliberate, and the wildcard is not the
security boundary.

Any identity that can create a pod in a namespace is already admin of that namespace: the
pod can name any ServiceAccount there and mount any Secret there, so it acts with every
permission those identities hold. Union's components create task pods in every work
namespace, so they hold that power whatever the rest of the rule list says. Narrowing
work-ns to named resources would make the role harder to read without making it safer.

The boundary is in two other places:

- **Where work-ns is bound.** At `singleNamespace: false` it is bound only in the work
  namespaces, by a RoleBinding the chart or `clusterresourcesync` writes in each one. It is
  never bound in the release namespace, where Union's own Deployments and Secrets live, and
  the chart refuses a `namespaces.static` that lists the release namespace. Each component's
  release-namespace access comes from its own `comp-ns-read` and `comp-ns-write` Roles.
- **The cluster-scoped grants.** These are listed rule by rule in
  [rbac-union.md](rbac-union.md#the-cluster-scoped-write-surface), and in single-namespace
  mode they are held to the allowlist below.

The chart keeps the all-groups wildcard in work-ns: `dataplane.rbac.emitSlot` refuses
`apiGroups: ['*']` in every other slot, and `tests/test-rbac-guards.sh` checks every
rendered role. Outside work-ns, a resource wildcard inside a named group is allowed only
for the Knative controllers' reads of their own API groups.

**Under `singleNamespace: true` the release namespace is the work namespace.** work-ns is a
Role bound there, so the wildcard applies to Union's own objects too: any component bound
to it can read Union's Secrets and change its Deployments. That blast radius is the accepted
cost of running in one namespace. Use `singleNamespace: false` if the components that launch
tasks must be unable to reach Union's own Secrets and Deployments.

## Plugin CRD reads at `singleNamespace: false`

At `singleNamespace: false` no limit namespace is set, so a CRD-backed task plugin's
informer watches its resource across every namespace. work-ns covers the plugin's calls
inside each work namespace, but a watch across all namespaces is authorized at cluster
scope, which no RoleBinding can grant. Each CRD you list in `taskPluginClusterReadRules` is
granted `list` and `watch` cluster-wide to leaseworker and, when it is enabled,
flytepropeller:

```yaml
taskPluginClusterReadRules:
  - apiGroups: [sparkoperator.k8s.io]         # spark
    resources: [sparkapplications]
  - apiGroups: [ray.io]                        # ray, and fastray's idle-cluster reaper
    resources: [rayjobs, rayclusters]
  - apiGroups: [kubernetes.dask.org]           # dask
    resources: [daskjobs]
  - apiGroups: [kubeflow.org]                  # kubeflow
    resources: [pytorchjobs, tfjobs, mpijobs]
  - apiGroups: [jobset.x-k8s.io]               # clustered-task
    resources: [jobsets]
```

The chart cannot derive this list from `enabled_plugins`: it cannot see which CRDs are
installed or what a plugin outside the stock set watches. The render fails on a wildcard in
any field, on any verb other than `get`, `list` or `watch`, and on a built-in group, because
the key is for CRDs and a cluster-wide read of the core group would reach every Secret.
The refused groups are the core group `""`, every group without a dot (a CRD's group always
has one), `rbac.authorization.k8s.io` and `certificates.k8s.io`. The plugins' writes
(create, delete, patch) stay in work-ns.

Under `singleNamespace: true` the key renders nothing: plugin informers are confined to the
release namespace there, which work-ns covers.

## The rule

`singleNamespace: true` — the chart default — runs Union in the release namespace and
confines the observability components to it. Prometheus and kube-state-metrics get
namespaced Roles and lose the metrics that exist only cluster-wide: Task-Level Monitoring,
`kube_node_*`, and accurate cost data. The full list is on the `singleNamespace` key in
`values.yaml`. `low_privilege` is the key's older name and still works as an alias.

`singleNamespace: false` trades that back: the observability components may read
cluster-wide, never write, and never touch secrets.

The flag is not a whole-chart namespace boundary. It scopes Union-authored workload RBAC
along with these two subcharts, and gates [app serving](#app-serving), namespace creation
and the leaseworker and flytepropeller priorityclasses. Outside its reach:

- a short list of cluster-scoped reads that remain in single-namespace mode
  ([below](#what-singlenamespace-still-reads-cluster-wide));
- the Helm hook cleanup job, which creates a ClusterRole in either mode;
- the uvol mount broker (on by default), which creates a PriorityClass and a CSIDriver in
  either mode;
- opencost and metrics-server, which are cluster-scoped when enabled;
- the `knative-operator` subchart, which ships its own cluster-scoped set when enabled.

A namespace-confined install identity is therefore not enough to deploy this chart; the
README's RBAC section covers what your install identity needs.

The flag decides RBAC by itself. How much kube-state-metrics collects with that access is
set separately, by layering `examples/values.full-privilege.yaml` (see below).

## What singleNamespace still reads cluster-wide

Single-namespace mode promises a bounded scope, not an absence of cluster-scoped access.
Some reads have no namespaced form, and the chart grants them rather than switch off the
feature that needs them. The list is fixed: `tests/test-rbac-guards.sh` renders every
single-namespace fixture, plus two renders with every optional component on, and fails if a
ClusterRole bound by a ClusterRoleBinding grants anything off the list.

| ClusterRole | Grant | When | Why |
|---|---|---|---|
| `<ns>-operator-cluster-read` | `nodes` list, watch | on by default | The operator's node informer (`operator/cmd/root.go`). It runs unless `config.operator.disableClusterPermissions` is set, and whenever any usage collector runs; startup blocks until it syncs. It backs the Legacy/Shadow billing collector and attributes a GPU to the node's accelerator label when the pod spec names none. Nodes are cluster-scoped, so `limitNamespace` cannot confine it. |
| `<ns>-operator-cluster-read` | `nodes` get, list, watch; `pods` get, list, watch with `clusterWidePods` | `config.operator.clusterHealth.nodeCapacity.enabled` | The cluster health snapshot's capacity report reads node shapes and allocatable resources, and with `clusterWidePods` the pods scheduled on them for per-pool usage, which a namespace-limited operator's own pod cache cannot see. Independent of `disableClusterPermissions` and of the informer's gate; it adds `get` to the same `nodes` rule. |
| `<ns>-nodeobserver-cluster-read` | `nodes` get, `pods` list | `nodeobserver.enabled` | nodeobserver reads the node it runs on, and lists that node's pods with an empty namespace and a `spec.nodeName` field selector — a cluster-scope request. |
| `<ns>-node-bootstrap-cluster-read` | `nodes` get | `nodeBootstrap.enabled` with `nodeBootstrap.startupTaintKey` set | union-node-readiness reads the node it runs on before removing the startup taint. |
| `dataplane-nginx-ingressclass` | `ingressclasses` get, list, watch | `ingress-nginx.enabled` | A scoped ingress-nginx controller still reads IngressClass, which is cluster-scoped; if the read is denied, the controller ignores every Ingress this chart renders. |
| `flyte-webhook-cleanup-<ns>` | `mutatingwebhookconfigurations` get, delete, on `flyte-pod-webhook` only | pre-upgrade hook | Deletes the webhook configuration chart versions before 2026.4.7 left behind. |

Writes are held to a stricter rule: a cluster-scoped write must be pinned to named objects.
The cleanup hook's `delete` above is the only pinned write. Two `nodes` `update` grants are
the unpinned exceptions, both off by default: nodeobserver's and node-bootstrap's
(`<ns>-node-bootstrap-cluster-write`, with a taint key set). Each removes a startup taint from
the node it runs on, and RBAC has no way to name the caller's own node.

Single-namespace mode withholds what is off the list: the operator's `/metrics` scrape of
the API server, which feeds its FlyteWorkflow-count and etcd-size throttles (the throttles
stay off), and prometheus' node and cadvisor discovery.

The leaseworker's Kubernetes event watcher, its fast-task orphan pod lists and the fastray
idle-cluster reaper need nothing from the list. Since
[cloud#18782](https://github.com/unionai/cloud/pull/18782) they run in the limit namespace,
which the release-namespace `work-ns` Role covers. A leaseworker image without that change
still watches `events.k8s.io` events in every namespace and is refused, so task status omits
Kubernetes events in this mode. `appVersion` `2026.10.0` predates the change.

`taskPluginClusterReadRules` cannot add to this list, because its entries are emitted only
at `singleNamespace: false`.

The operator follows `disableClusterPermissions` and `collectUsages` as set; single-namespace
mode forces neither. It confines its pod and pod-metrics reads to `limitNamespace` itself
(`usageNamespace` in `operator/cmd/root.go`), so usage collection needs only the nodes read
cluster-wide.

Third-party subcharts that ship their own RBAC — kube-prometheus-stack (`monitoring`),
metrics-server, opencost, knative-operator, ingress-nginx's own controller RBAC,
dcgm-exporter and fluent-bit — are outside this list, and `singleNamespace` does not govern
them. All are off by default except fluent-bit, which renders no RBAC here.

## Why we write prometheus and kube-state-metrics RBAC ourselves

A subchart cannot see `singleNamespace`, because Helm values are static. Leaving RBAC to
those two subcharts would need a second values file that moves with the flag, and nothing at
render time would catch the two drifting apart. So both are pinned to `rbac.create: false`
and `templates/prometheus/rbac.yaml` writes the grant instead, since a template can branch
and a value cannot. `templates/prometheus/validate.yaml` stops the render if either
subchart's RBAC is switched back on.

The kube-state-metrics rules come from the `collectors` list, so a new collector cannot end
up unauthorized: an unmapped one fails the render.

### What the flag can't reach

Two kube-state-metrics values become flags on its Deployment, which the subchart renders,
so none of our templates can branch on them:

- **`collectors`** → `--resources`. What it asks the API server for.
- **`namespaces` + `releaseNamespace`** → `--namespaces`. Which namespaces it asks about: the
  named ones, plus the release namespace when `releaseNamespace` is set, deduped. When both
  are empty the subchart drops the flag, and kube-state-metrics reads *every* namespace.

The defaults match the namespaced install, so every request is covered by the grant: four
collectors, release namespace only. Requesting more than the grant covers leaves
kube-state-metrics running and logging the denial every few seconds for the life of the
pod. `templates/prometheus/rbac.yaml` refuses to render a cluster-scoped collector under
`singleNamespace` to prevent that.

`examples/values.full-privilege.yaml` is the other half of `singleNamespace: false`: it adds
the `nodes` and `namespaces` collectors and drops `--namespaces`, so `kube_node_*`,
`kube_namespace_labels` and task pods in project namespaces are all collected. Without it,
`singleNamespace: false` grants the cluster-wide read but collects like a namespaced
install. Task pod *utilization* is independent of this, because `container_*` comes from
the cadvisor job, which is node-scoped and namespace-blind; requests and limits depend on it.

## What each subchart gets

| Subchart | Default | `singleNamespace: true` | `singleNamespace: false` |
|---|---|---|---|
| prometheus | on | namespaced Role (ours) | ClusterRole (ours) |
| kube-state-metrics | on | namespaced Role, 4 collectors | ClusterRole, 6 with the overlay |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role + IngressClass ClusterRole | same |
| opencost | off | cluster-wide read | same |
| metrics-server | off | cluster read + `kube-system` write | same |

Only the first two follow the flag. The rest are fixed in either mode.

Out of scope: the deprecated knative-operator and kube-prometheus-stack subcharts.

## App serving

Left unset, `apps.enabled` is on in either mode, as it has always been, so the default
install, which is single-namespace, runs app serving. Under `singleNamespace: true` that brings
the Knative stack's cluster-wide reads described below, the one exception to single-namespace
mode's fixed list of cluster-scoped grants. Set `apps.enabled: false` (or the deprecated
`serving.enabled: false`) to hold the install to that list.

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
`cluster-read` ClusterRoles and the webhook its name-pinned `cluster-write`, while the
work-namespace grant, `<ns>-work-ns`, becomes a Role in the release namespace, where the apps
run. The vendored Knative stack renders whenever app serving is on and delivered by this
chart. The deprecated `knative-operator` path (`gateway.enabled: false`) is out of scope
here, as it is everywhere else in this document.

The `apps.enabled` default lives in the helper's final branch, not in `values.yaml`.
Writing `apps.enabled: false` in `values.yaml` would make the key *set*, and precedence is
`apps.enabled > serving.enabled > not singleNamespace`, so the deprecated `serving.enabled`
would stop being consulted. Every install still using it would lose app serving while
explicitly asking for it. `tests/values/dataplane.aws.zero-trust-serving-enabled.yaml` is the
golden that catches that.

App serving is the one component the flag cannot narrow. Its RBAC is declared per binary
through this chart's slot framework, like every other component's, and every grant that can
be namespaced is. The rest follows from what the *images* do:

- **The watches are unscoped.** The deployments take only `SYSTEM_NAMESPACE` (where
  Knative's own config lives); upstream ships no namespace-scoped install, and the binaries
  take the shared, unfiltered informers from `knative.dev/pkg` without scoping them to a
  namespace. Those reads go out with an empty namespace, which Kubernetes authorizes as a
  cluster-scope check. Each binary holds a subset: the webhook watches only the two
  webhook-configuration kinds, the activator watches Services, Endpoints and Revisions, the
  autoscaler adds Pods, Deployments, leases and HPAs, and `net-kourier` adds Ingresses.
  **Every one of those subsets is cluster-scoped.** A namespaced Role would authorize none of
  it: controller, webhook and activator would report Ready while every read is denied. That
  is the same shape the prometheus and kube-state-metrics guards prevent, and no values key
  exists to guard on.

So app serving reads every namespace in the cluster. `singleNamespace: true` promises that
Union's cluster-scoped reads are a fixed list, and Knative's are on it only when app serving
is explicitly on: the scope allowlist in `tests/test-rbac-guards.sh` names them under that
condition. The webhook configurations confirm this from the other direction: every rule has
`scope: "*"` and omits `namespaceSelector`, so admission intercepts cluster-wide regardless
of RBAC.

The default is all the flag does here; the Knative grants are the same in both modes. The
release notes give the per-component breakdown.

**Why the stack renders whole or not at all.** Rendering `apps.enabled: true` without the
stack would be wrong in a familiar way: the operator would keep advertising app serving and
keep its (namespaced) `serving.knative.dev` grant, and every Knative Service it created would
sit unreconciled with nothing reporting why. So `apps.enabled` means one thing in both
modes, and the operator's config and Role stay correct by construction.

**What `apps.enabled: false` keeps.** The Envoy gateway, dataproxy and tunnel-service ingress
gate on `serving.renderGateway` — `gateway.enabled` with either app serving or zero trust —
so under zero trust they survive `apps.enabled: false` on their own. They hold no
cluster-scoped RBAC, and their static dataplane routes are what zero trust is. Turning app
serving off never costs zero trust.

`tests/values/dataplane.aws.zero-trust{,-overrides,-serving-enabled}.yaml` turn app serving
on and so pin `low_privilege: false`, the alias. `-apps-disabled` leaves scope at the
default, which is what lets it prove `apps.enabled` beats `serving.enabled`: a regression
reading it as true would render the Knative stack into that golden.
`tests/test-rbac-guards.sh` asserts the default and the opt-in under `singleNamespace`.

## Notes

**prometheus.** Read-only on services, endpoints, pods, ingresses, configmaps and
endpointslices, plus nodes and the node metrics endpoints at `singleNamespace: false`. It
never reads secrets and never writes, in either mode.

The namespaced Role drops cluster-scoped resources. Naming them there is legal but never
matches, which is how `kubernetes-cadvisor` returned 403s for three months. For the same
reason the chart does not render that scrape job under `singleNamespace`: it needs
cluster-wide node discovery, and it is the only source of `container_cpu_usage_seconds_total`
and `container_memory_working_set_bytes`. Those panels read "no data" in single-namespace
mode, by design.

Verified on a live cluster: with only the namespaced Role, prometheus finds and scrapes
every target in its own namespace — 4/4 up, no RBAC errors.

At `singleNamespace: false` the ClusterRole name is a fixed string, so **one dataplane per
cluster** is the supported model. Nothing enforces it: `helm install` refuses a second
release on ownership, but ArgoCD — the deployment path this chart is built for — applies
shared resources unless the Application sets `FailOnSharedResource=true`. There, the later
sync can rewrite the binding subject to its own namespace, surfacing at most a
`SharedResourceWarning` condition, and the first release's prometheus loses its
authorization. Treat this as a constraint to respect, because nothing will reliably stop you.

The cluster-wide read at `singleNamespace: false` is wider than the rendered scrape jobs
use: every job but `kubernetes-cadvisor` discovers with `own_namespace: true`. That is
deliberate. `singleNamespace: false` is a choice of permission posture, not a permission set
derived from the jobs. Helm cannot parse arbitrary `prometheus.extraScrapeConfigs` to work
out what a job added there needs, so the grant tracks the pinned subchart's own read-only
discovery profile. That is what lets a job added there reach `prometheus.io/scrape` targets
outside the release namespace.

**kube-state-metrics.** Four collectors out of 28 by default (`pods`, `deployments`,
`daemonsets`, `resourcequotas`), list/watch only, chosen to match the series the control
plane's metrics gateway accepts. Dropping the other 24 also drops `secrets`. The
full-privilege overlay adds `nodes` and `namespaces`; omitting them costs `kube_node_*` and
`kube_namespace_labels`, and the latter is the join key for most pod-level aggregates, so
pod-level dashboards degrade rather than just losing node panels.

Grants are derived from whatever `collectors` names, so the two always match: an unmapped
collector fails the render, and so does a cluster-scoped one under `singleNamespace`. See
[What the flag can't reach](#what-the-flag-cant-reach) for the collection scope.

The binding names kube-state-metrics' real ServiceAccount, derived from the subchart's own
naming rules for every release name.

Don't add `metricRelabelings` here — nothing in the dependency tree reads it. The filter
that actually runs is the scrape job's `metric_relabel_configs` in
`prometheus.extraScrapeConfigs`.

Because both subcharts are pinned to `rbac.create: false`, the RBAC half of their own
features never renders. `rbac.extraRules` is dropped. `kubeRBACProxy`, `customResourceState`
and `autosharding` fare worse: the *feature* still renders — proxy sidecar,
custom-resource config, sharded StatefulSet — but the permissions it needs
(token/subject-access-review `create`, the configured CRD reads, pod/statefulset reads) are
missing. The result is a running component that cannot do its job, the same silent shape
this chart writes RBAC to avoid.

All four are unsupported, and none is a drop-in. `$ksmRules` in
`templates/prometheus/rbac.yaml` maps one collector to one apiGroup/resource pair at
`list, watch`, so it cannot express arbitrary `extraRules` or `create` on tokenreviews and
subjectaccessreviews. `kubeRBACProxy` also serves authenticated HTTPS, which the chart's
kube-state-metrics scrape job (plain HTTP, no bearer token) could no longer reach.
Supporting any of them means extending `rbac.yaml` and the scrape config together.

`templates/prometheus/validate.yaml` refuses all four at render time, naming what each one
needs. Each would otherwise deploy a kube-state-metrics that starts, stays ready, and
returns none of the series you asked for.

**fluent-bit.** Calls the Kubernetes API nowhere in this chart. The subchart's cluster-wide
read on namespaces and pods serves a `kubernetes` filter, and this chart configures none:
pod, namespace and container names come from the log file path, and that path *is* the
object key.

Three keys reverse this: `fluentbit.additionalFilters` (if you paste in a `kubernetes`
filter), `fluentbit.rbac.nodeAccess` and `fluentbit.rbac.eventsAccess`. Setting any of them
requires setting `fluentbit.rbac.create: true` by hand as well, because nothing derives it.
On their own, the last two render nothing while the filter runs unauthorized.

**dcgm-exporter.** Uses no Kubernetes API: GPU-to-pod mapping reads the kubelet podresources
socket and the metrics CSV is a volume mount, so the pod does not mount a service account
token.

Three keys change that, each granting cluster-wide read on pods and resourceslices:
`kubernetes.enablePodLabels`, `kubernetes.enablePodUID`, `kubernetesDRA.enabled`. Setting
`kubernetes.rbac.create: false` covers only the first two; `kubernetesDRA.enabled` grants
the ClusterRole regardless.

Prometheus looks for dcgm-exporter in the release namespace, where the subchart deploys it,
so an instance managed elsewhere (by the NVIDIA GPU operator, say) is not scraped.

**ingress-nginx.** Confined to the release namespace in both modes, which is where all of
this chart's endpoints live. Unscoped, the controller reads secrets, configmaps, pods,
endpoints and nodes across the whole cluster — secrets because TLS certificates can be
referenced from an Ingress anywhere. Scoped, that becomes a namespaced Role; the only
cluster-scoped object left is the IngressClass, which has no namespaced form.

The controller ignores an Ingress outside the release namespace and logs no error or
warning. To serve one from another namespace, set `rbac.scope` and `controller.scope.enabled`
both back to `false`. They must move together: the subchart errors on `rbac.scope` alone,
and `templates/ingress-nginx/validate.yaml` catches the reverse, which is otherwise silent.
That check applies only when the subchart creates the controller's RBAC; at
`rbac.create: false` the subchart renders no controller Role or ClusterRole, and the scope of
whatever you supply is yours to get right. (The admission-webhook patch job carries its own
RBAC under `controller.admissionWebhooks.patch.rbac.create` — off by default here, and
unrelated to what the controller can read.)

Those checks read the scope *values*. `controller.extraArgs.watch-namespace` also reaches
`--watch-namespace`, appended after the scope-derived one, so it wins, and no check inspects
it. Under scoped RBAC it produces the silent non-reconciliation the guard exists to
prevent. As with `rbac.create: false` above, a raw passthrough is yours to keep consistent;
use `controller.scope.namespace`, which is checked.

**opencost.** Cluster-wide `get`/`list`/`watch` whenever it is enabled, in either scope
mode. It prices the whole cluster, so a namespaced grant would leave it nothing to price,
and the subchart offers no key to narrow it. `singleNamespace` does not reach it.
`tests/values/dataplane.opencost.yaml` pins the grant so a subchart bump that widens it
shows up in review.

**metrics-server.** Left as-is; it is cluster-scoped by design. It needs an APIService, the
`system:auth-delegator` binding, and a RoleBinding in `kube-system` that cannot be
overridden, so an operator confined to the release namespace gets a hard 403 from `helm
upgrade`. `rbac.create: false` leaves it unable to authenticate. It also grants
`configmaps` and `namespaces` beyond upstream's own v0.7.2 manifest; narrowing that would
mean forking the subchart.
