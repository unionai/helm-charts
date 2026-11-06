# Third-party subchart RBAC

This page lists what each dependency subchart is allowed to read, and why.
[App serving](#app-serving) is covered here too, although it is not a subchart. It is the one
component whose cluster-wide reads `singleNamespace` cannot narrow, so `singleNamespace` turns
it off by default instead.

For Union's own components, including the slot model, the work-namespace bindings and the
identities, see [rbac-union.md](rbac-union.md). Two of them are covered here because they
shape both scope modes: [the work-ns wildcard](#the-work-ns-wildcard) and [plugin CRD reads
at `singleNamespace: false`](#plugin-crd-reads-at-singlenamespace-false).

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
  writes in each one ([namespaces.md](namespaces.md#three-routes-to-create-them)).
  - The release namespace, which holds Union's own Deployments and Secrets, never gets the
    binding, and the chart refuses a `namespaces.static` that lists it.
  - Each component's release-namespace access comes from its own `comp-ns-read` and
    `comp-ns-write` Roles.
- **The cluster-scoped grants.** [rbac-union.md](rbac-union.md#the-cluster-scoped-write-surface)
  lists them rule by rule. In single-namespace mode they are held to the allowlist below.

The all-groups wildcard exists only in `work-ns`. `dataplane.rbac.emitSlot` refuses
`apiGroups: ['*']` in every other slot, and `tests/test-rbac-guards.sh` checks every
rendered role. Outside `work-ns`, a resource wildcard inside a named group is allowed only
for the Knative controllers' reads of their own API groups.

Under `singleNamespace: true` the release namespace is the work namespace. `work-ns` is a
Role bound there, so the wildcard covers Union's own objects: any component bound to it can
read Union's Secrets and change its Deployments. That blast radius is the accepted cost of
running in one namespace. If the components that launch tasks must be kept away from Union's
own Secrets and Deployments, use `singleNamespace: false`.

## Plugin CRD reads at `singleNamespace: false`

At `singleNamespace: false` no limit namespace is set, so a CRD-backed task plugin's
informer watches its resource across every namespace. `work-ns` covers the plugin's calls
inside each work namespace. A watch across all namespaces, however, is authorized at cluster
scope, which no RoleBinding can grant. So the chart grants `list` and `watch` cluster-wide on
each CRD you list in `taskPluginClusterReadRules`, to leaseworker and, when it is enabled,
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

The chart cannot derive this list from `enabled_plugins`, because it cannot see which CRDs
are installed or what a plugin outside the stock set watches.

The render fails on a wildcard in any field, on a verb other than `get`, `list` or `watch`,
and on a built-in group. The key is for CRDs, and a cluster-wide read of the core group
would reach every Secret. The refused groups are:

- the core group `""`
- every group without a dot, since a CRD's group always has one
- `rbac.authorization.k8s.io`
- `certificates.k8s.io`

The plugins' writes stay in `work-ns`. Those writes are `create`, `delete` and `patch`. Under
`singleNamespace: true` the key renders nothing, because plugin informers are confined to
the release namespace, which `work-ns` covers.

## The rule

`singleNamespace: true` is the chart default and runs Union in the release namespace. Its
workloads write only there, and any cluster-scoped access is read-only and on a fixed list.
Prometheus and kube-state-metrics keep their release-namespace scrapes in namespaced Roles.
They read the node- and cluster-level telemetry that has no namespaced form through
read-only cluster roles. That covers cadvisor through the API server proxy, the API server's
`/metrics`, and the `nodes` and `namespaces` collectors, so Task-Level Monitoring and
`kube_node_*` work in either mode. `low_privilege` is the key's older name and still works
as an alias.

Prometheus holds the same grant in either mode. kube-state-metrics' grant follows the
namespaces it collects from. `singleNamespace: true` holds those to the release namespace,
and `singleNamespace: false` lets you widen them ([below](#what-the-flag-cant-reach)).
Neither writes, and neither reads secrets.

`singleNamespace` scopes Union-authored workload RBAC and where kube-state-metrics may
collect, and it gates namespace creation. It is not a whole-chart namespace boundary,
because these are outside its reach:

- app serving, which is on by default in either mode ([below](#app-serving))
- a short list of cluster-scoped reads that remain in single-namespace mode
  ([below](#what-singlenamespace-still-reads-cluster-wide))
- the Helm hook cleanup job, which creates a ClusterRole in either mode
- the uvol mount broker, which is on by default and creates a PriorityClass and a CSIDriver
  in either mode
- the leaseworker's PriorityClass, and flytepropeller's when it is enabled, which are
  created in either mode unless `priorityClass.create` is false
- opencost and metrics-server, which are cluster-scoped when enabled
- the `knative-operator` subchart, which ships its own cluster-scoped set when enabled

A namespace-confined install identity is therefore not enough to deploy this chart. The
README's RBAC section covers what your install identity needs.

## What singleNamespace still reads cluster-wide

Single-namespace mode bounds the scope and still grants some cluster-scoped reads. Some
reads have no namespaced form, and the chart grants them rather than switching off the
feature that needs them. The list is fixed. `tests/test-rbac-guards.sh` renders every
single-namespace fixture, plus two renders with every optional component on, and fails if a
ClusterRole bound by a ClusterRoleBinding grants anything off the list.

| ClusterRole | Grant | When | Why |
|---|---|---|---|
| `<ns>-operator-cluster-read` | `nodes` list, watch | on by default | The operator's node informer (`operator/cmd/root.go`). It runs unless `config.operator.disableClusterPermissions` is set, and whenever any usage collector runs. Startup blocks until it syncs. It backs the Legacy/Shadow billing collector, and it attributes a GPU to the node's accelerator label when the pod spec names none. Nodes are cluster-scoped, so `limitNamespace` cannot confine it. |
| `<ns>-operator-cluster-read` | `nodes` get, list, watch; `pods` get, list, watch with `clusterWidePods` | `config.operator.clusterHealth.nodeCapacity.enabled` | The cluster health snapshot's capacity report reads node shapes and allocatable resources. With `clusterWidePods` it also reads the pods scheduled on them for per-pool usage, which a namespace-limited operator's own pod cache cannot see. This grant does not depend on `disableClusterPermissions` or on the informer's gate, and it adds `get` to the same `nodes` rule. |
| `<ns>-operator-cluster-read` | `/metrics` get | on by default | The operator reads the API server's own metrics for its FlyteWorkflow-count and etcd-size throttles (`operator/pkg/apiserver_stats.go`). Without it the poll fails every interval and the throttles never engage. |
| `<ns>-nodeobserver-cluster-read` | `nodes` get, `pods` list | `nodeobserver.enabled` | nodeobserver reads the node it runs on, and lists that node's pods with an empty namespace and a `spec.nodeName` field selector, which is a cluster-scope request. |
| `<ns>-node-bootstrap-cluster-read` | `nodes` get | `nodeBootstrap.enabled` with `nodeBootstrap.startupTaintKey` set | union-node-readiness reads the node it runs on before removing the startup taint. |
| `<ns>-prometheus-cluster-read` | `nodes` list, watch; `nodes/proxy` get; `/metrics` get | `prometheus.enabled` | Prometheus uses these for node discovery, for the kubelet's cadvisor endpoint through the API server proxy, and for the API server's own `/metrics`. The proxy needs no network path from Prometheus to the kubelet. The API server job's endpoint discovery reads only the `default` namespace, through the Role `<ns>-prometheus-apiserver-discovery` there. |
| `<ns>-kube-state-metrics-cluster-read` | `nodes`, `namespaces` list, watch | a cluster-scoped collector is listed (both are by default) | These back `kube_node_*` and `kube_namespace_labels`, which the control plane's metrics gateway accepts. Namespaced collectors stay in the release-namespace Role. |
| `dataplane-nginx-ingressclass` | `ingressclasses` get, list, watch | `ingress-nginx.enabled` | A scoped ingress-nginx controller still reads IngressClass, which is cluster-scoped. If the read is denied, the controller ignores every Ingress this chart renders. |
| `flyte-webhook-cleanup-<ns>` | `mutatingwebhookconfigurations` get, delete, on `flyte-pod-webhook` only | pre-upgrade hook | The hook deletes the webhook configuration that chart versions before 2026.4.7 left behind. |

Writes are held to a stricter rule: a cluster-scoped write must be pinned to named objects.
The cleanup hook's `delete` above is the only pinned write. Two `nodes` `update` grants are
unpinned exceptions, and both are off by default. One belongs to nodeobserver. The other is
node-bootstrap's `<ns>-node-bootstrap-cluster-write`, which renders when a taint key is set.
Each removes a startup taint from the node it runs on, and RBAC cannot name the caller's own
node.

The leaseworker's Kubernetes event watcher, its fast-task orphan pod lists and the fastray
idle-cluster reaper stay off the list. Since
[cloud#18782](https://github.com/unionai/cloud/pull/18782) they run in the limit namespace,
which the release-namespace `work-ns` Role covers. A leaseworker image that predates that
change still watches `events.k8s.io` events in every namespace. The API server refuses the
watch, so task status omits Kubernetes events in this mode. `appVersion` `2026.10.0`
predates the change.

`taskPluginClusterReadRules` cannot add to this list, because its entries are emitted only
at `singleNamespace: false`.

The operator honors `disableClusterPermissions` and `collectUsages` as set in either mode.
It confines its pod and pod-metrics reads to `limitNamespace` itself, in `usageNamespace` in
`operator/cmd/root.go`, so usage collection needs only the nodes read cluster-wide.

Third-party subcharts that ship their own RBAC are outside this list, and `singleNamespace`
does not govern them. They are kube-prometheus-stack (`monitoring`), metrics-server,
opencost, knative-operator, ingress-nginx's own controller RBAC, dcgm-exporter and
fluent-bit. All are off by default except fluent-bit, which renders no RBAC here.

## Why we write prometheus and kube-state-metrics RBAC ourselves

The subcharts' own RBAC grants their upstream discovery profile, which is cluster-wide reads
of pods, services, endpoints, configmaps and every kube-state-metrics resource, whatever the
chart's scrape jobs use. So both subcharts are pinned to `rbac.create: false`.
`templates/prometheus/rbac.yaml` writes the grant instead, holding each to what this chart's
configuration asks for, the same in either scope mode. `templates/prometheus/validate.yaml`
stops the render if either subchart's RBAC is switched back on.

The kube-state-metrics rules come from the `collectors` list, so every collector in the list
has a rule. The render fails on a collector the chart has no mapping for.

### What the flag can't reach

Two kube-state-metrics values become command-line flags on its Deployment. The subchart
renders the Deployment, so none of this chart's templates can branch on them:

- **`collectors`** becomes `--resources`, which sets what kube-state-metrics asks the API
  server for.
- **`namespaces` and `releaseNamespace`** become `--namespaces`, which sets the namespaces it
  asks about. That is the named ones plus the release namespace when `releaseNamespace` is
  set, with duplicates removed. When both are empty the subchart drops the flag, and
  kube-state-metrics reads every namespace.

The defaults are six collectors, with the namespaced ones collecting in the release
namespace only, in either mode. The chart reads both values and grants exactly what they ask
for. That is a Role in each named namespace, or a ClusterRole when kube-state-metrics reads
every namespace. `singleNamespace: true` refuses any namespace other than the release
namespace. The cluster-scoped collectors, `nodes` and `namespaces`, get their own read-only
cluster role in either mode, so the six match what the managed dataplanes collect.

`examples/values.full-privilege.yaml` drops `--namespaces` so that task pods in project
namespaces are collected too, and the grant widens to a ClusterRole with it. Without that
file, `singleNamespace: false` still collects namespaced resources only in the release
namespace. Task pod utilization does not depend on this, because `container_*` comes from the
cadvisor job, which is node-scoped and namespace-blind. Pod requests and limits do depend on
it.

## What each subchart gets

| Subchart | Default | `singleNamespace: true` | `singleNamespace: false` |
|---|---|---|---|
| prometheus | on | namespaced Roles for discovery, plus a read-only cluster role for nodes, the kubelet proxy and `/metrics` (ours) | same |
| kube-state-metrics | on | a Role where it collects namespaced resources, plus a read-only cluster role for `nodes` and `namespaces`; 6 collectors | same; a ClusterRole for the namespaced collectors when it collects every namespace |
| fluent-bit | on (off on GCP) | none | none |
| dcgm-exporter | off | none | none |
| ingress-nginx | off | namespaced Role + IngressClass ClusterRole | same |
| opencost | off | cluster-wide read | same |
| metrics-server | off | cluster read + `kube-system` write | same |

Only the first two follow `singleNamespace`. The rest are fixed in either mode.

The deprecated knative-operator and kube-prometheus-stack subcharts are out of scope here.

## App serving

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
it. The deprecated `knative-operator` path is out of scope here, as it is everywhere else in
this document. It applies when `gateway.enabled` is false.

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

## Notes

**prometheus.** The grant is the same in either mode and read-only, and it is exactly what
the scrape jobs discover:

- `list` and `watch` on endpoints, services and pods in the release namespace
  (`union-operator-prometheus-rbac`)
- `list` and `watch` on endpoints in `default`, for the API server
  (`<ns>-prometheus-apiserver-discovery`)
- in `<ns>-prometheus-cluster-read`:
  - `list` and `watch` on nodes for cadvisor discovery
  - `get` on `nodes/proxy` to reach the kubelet through the API server
  - `get` on `/metrics` for the API server

It never reads secrets or configmaps and never writes.

A namespaced Role cannot carry a cluster-scoped resource. Naming one there is legal but never
matches, which is how `kubernetes-cadvisor` returned 403 responses for three months. The node reads
live in the cluster role instead, so the cadvisor job runs in both modes, as does the API
server job. The cadvisor job is the only source of `container_cpu_usage_seconds_total` and
`container_memory_working_set_bytes`.

The cluster-scoped names carry the release namespace, so two dataplanes in one cluster get
separate objects.

A job added under `prometheus.extraScrapeConfigs` that discovers outside the release
namespace, or outside `default` for endpoints, is not covered. That is because Helm cannot parse it
to work out what it needs. Grant its discovery reads yourself, in that namespace.

**kube-state-metrics.** By default it runs six of its 28 collectors, read-only with `list`
and `watch`. The six are `namespaces`, `nodes`, `pods`, `deployments`, `daemonsets` and
`resourcequotas`. They are the set the managed dataplanes collect and the series the control
plane's metrics gateway accepts. Dropping the other 22 also drops `secrets`. Omitting `nodes`
and `namespaces` costs `kube_node_*` and `kube_namespace_labels`. The latter is the join key
for most pod-level aggregates, so pod-level dashboards degrade instead of only losing node
panels.

The binding names kube-state-metrics' real ServiceAccount, derived from the subchart's own
naming rules for every release name.

Don't add `metricRelabelings` here, because nothing in the dependency tree reads it. The
filter that runs is the scrape job's `metric_relabel_configs` in
`prometheus.extraScrapeConfigs`.

Because both subcharts are pinned to `rbac.create: false`, the RBAC half of their own
features never renders, and `rbac.extraRules` is dropped. `kubeRBACProxy`,
`customResourceState` and `autosharding` would fare worse. The feature would still render, as
a proxy sidecar, custom-resource config or sharded StatefulSet. The permissions it needs
would be missing, namely token and subject-access-review `create`, the configured CRD reads,
and pod and statefulset reads.

All four are unsupported, and `templates/prometheus/validate.yaml` refuses each at render
time, naming what it needs. Without the refusal each would deploy a kube-state-metrics that
starts, stays ready, and returns none of the series you asked for. `$ksmRules` in `templates/prometheus/rbac.yaml` maps one collector to one apiGroup/resource
pair at `list, watch`, so it cannot express arbitrary `extraRules`, or `create` on
tokenreviews and subjectaccessreviews. `kubeRBACProxy` also serves authenticated HTTPS, which
the chart's kube-state-metrics scrape job, using plain HTTP without a bearer token, could no
longer reach. Supporting any of them means extending `rbac.yaml` and the scrape config
together.

**fluent-bit.** fluent-bit calls the Kubernetes API nowhere in this chart. The subchart's
cluster-wide read on namespaces and pods serves a `kubernetes` filter, and this chart
configures none. Pod, namespace and container names come from the log file path, which is
the object key.

Three keys change this: `fluentbit.additionalFilters`, when you paste in a `kubernetes`
filter, `fluentbit.rbac.nodeAccess` and `fluentbit.rbac.eventsAccess`. Setting any of them
also requires setting `fluentbit.rbac.create: true` by hand, because nothing derives it.
Set on their own, the last two render nothing, and the `kubernetes` filter then runs
unauthorized.

**dcgm-exporter.** dcgm-exporter uses no Kubernetes API. GPU-to-pod mapping reads the kubelet
podresources socket and the metrics CSV is a volume mount, so the pod does not mount a
service account token.

Three keys change that, and each grants cluster-wide read on pods and resourceslices. They
are `kubernetes.enablePodLabels`, `kubernetes.enablePodUID` and `kubernetesDRA.enabled`.
Setting `kubernetes.rbac.create: false` covers only the first two, because
`kubernetesDRA.enabled` grants the ClusterRole regardless.

Prometheus looks for dcgm-exporter in the release namespace, where the subchart deploys it,
so an instance managed elsewhere, such as by the NVIDIA GPU operator, is not scraped.

**ingress-nginx.** The controller is confined to the release namespace in both modes, which
is where all of this chart's endpoints live. Unscoped, it reads secrets, configmaps, pods,
endpoints and nodes across the whole cluster. It reads secrets because TLS certificates can
be referenced from an Ingress anywhere. Scoped, that becomes a namespaced Role. The only
cluster-scoped object left is the IngressClass, which has no namespaced form.

The controller ignores an Ingress outside the release namespace and logs no error or
warning. To serve one from another namespace, set both `rbac.scope` and
`controller.scope.enabled` back to `false`. They must move together. The subchart errors on
`rbac.scope` alone, and `templates/ingress-nginx/validate.yaml` catches the reverse, which is
otherwise silent. That check applies only when the subchart creates the controller's RBAC.
At `rbac.create: false` the subchart renders no controller Role or ClusterRole, and the
scope of whatever you supply is yours to get right. The admission-webhook patch job carries
its own RBAC under `controller.admissionWebhooks.patch.rbac.create`. That key is off by
default here and does not affect what the controller can read.

Those checks read the scope values. `controller.extraArgs.watch-namespace` also reaches
`--watch-namespace`, appended after the scope-derived one, so it wins, and no check inspects
it. Under scoped RBAC it leaves the controller silently not reconciling Ingresses, which is
what the guard exists to prevent. As with `rbac.create: false` above, you keep a raw
passthrough consistent yourself. Use `controller.scope.namespace`, which is checked.

**opencost.** opencost holds cluster-wide `get`, `list` and `watch` whenever it is enabled, in
either scope mode. It prices the whole cluster, so a namespaced grant would leave it nothing
to price, and the subchart offers no key to narrow it. `singleNamespace` does not govern it.
`tests/values/dataplane.opencost.yaml` pins the grant, so a subchart bump that widens it
shows up in review.

**metrics-server.** The chart leaves it as-is, because it is cluster-scoped by design. It
needs an APIService, the `system:auth-delegator` binding and a RoleBinding in `kube-system`,
and the RoleBinding cannot be overridden. An install identity confined to the release
namespace therefore gets a 403 from `helm upgrade`. `rbac.create: false` leaves it unable to
authenticate. The subchart also grants `configmaps` and `namespaces` beyond upstream's own
v0.7.2 manifest, and narrowing that would mean forking it.
