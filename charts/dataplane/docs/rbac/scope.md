# Scope: `singleNamespace`

`singleNamespace` decides whether Union runs in the release namespace with namespaced
`Role`s or across per-project namespaces with `ClusterRole`s. This page covers what each mode
grants.

## What single-namespace mode promises

`singleNamespace: true`, the default, still grants some cluster-scoped permissions, because
some features need access that only exists cluster-wide, such as node reads, node-level
metrics and Knative's informers. The mode reduces the permission set to what those features
need. It promises:

- Union's workloads, including tasks and apps, run in the release namespace. Every grant that
  can be namespaced is namespaced, for Union's components, Prometheus and kube-state-metrics
  alike. The chart creates no namespaces.
- Cluster-scoped reads come only from a fixed allowlist, which `tests/test-rbac-guards.sh`
  enforces and [the table below](#what-singlenamespace-still-reads-cluster-wide)
  explains entry by entry. The allowlist holds:
  - the operator's node informer and API server metrics
  - Prometheus and kube-state-metrics, for node- and cluster-level telemetry
  - Knative's informers while app serving is on, which is the default
  - nodeobserver, node-bootstrap and ingress-nginx, when enabled
- Cluster-scoped writes are pinned to named objects, such as the pre-upgrade hook that deletes
  the legacy `flyte-pod-webhook`. The exceptions are nodeobserver and node-bootstrap, both off
  by default, which each remove a startup taint from their own node.

Usage collection, the operator's node informer and API server throttles, Task-Level
Monitoring and node-level metrics run in both modes. The leaseworker, flytepropeller and uvol
mount broker PriorityClasses are created in both modes too. Set `priorityClass.create: false`
on a component if you manage its class yourself. kube-state-metrics collects namespaced
resources in the release namespace in both modes. Helm cannot derive kube-state-metrics
settings from the flag, so to collect from project namespaces under `singleNamespace: false`,
also layer `examples/values.full-privilege.yaml`. The kube-state-metrics grant follows those
settings.

App serving is on by default in either mode. Under `singleNamespace: true`, the Knative
binaries read cluster-wide however their RBAC is written, so app serving brings their
cluster-scoped reads with it. This is the one exception to the fixed allowlist. Set
`apps.enabled: false` to hold the install to that list.

With `gateway.enabled: false`, app serving comes from the deprecated `knative-operator`
subchart. It brings its own cluster-scoped RBAC, listed in the table below, under either
`singleNamespace` setting. `gateway.enabled` defaults to `true` whether zero trust is on or
off, so turning zero trust off keeps the vendored gateway. The Envoy gateway, dataproxy and tunnel ingress work
regardless of `apps.enabled`. See [app-serving.md](app-serving.md).

## `singleNamespace` is not a whole-chart namespace boundary

`singleNamespace` scopes Union-authored workload RBAC and where kube-state-metrics may
collect, and it gates namespace creation. The components below hold cluster-scoped
permissions in either mode, so deploying the chart takes more than a namespace-confined
install identity. `singleNamespace` leaves the subcharts' own RBAC alone.

| Component | Default | Cluster-scoped grant |
| --- | --- | --- |
| operator | **on** | `nodes` list and watch, for its node informer. Off with `config.operator.disableClusterPermissions: true`, which also stops the Legacy/Shadow billing collector and GPU attribution by node label |
| Helm hook cleanup | **on** | one ClusterRole, pinned by `resourceNames` to a single MutatingWebhookConfiguration |
| uvol mount broker | **on** | a PriorityClass and a CSIDriver |
| `knative-operator` subchart | off | 7 ClusterRoles and 7 ClusterRoleBindings of its own. Leave it off on the zero-trust path, where this chart provides app serving instead. |
| nodeobserver | off | `nodes` get and `update`, plus cluster-wide `pods` list. `nodes` is cluster-scoped, and the API server authorizes a pod list with an empty namespace and a `spec.nodeName` selector as cluster-scoped too. The `update` removes a startup taint from its own node and is unpinned by name |
| node-bootstrap | off | `nodes` get and `update` when `nodeBootstrap.startupTaintKey` is set. The `update` removes the startup taint from its own node and is unpinned by name |
| opencost | off | cluster-wide read. It prices the whole cluster, and no key narrows it |
| metrics-server | off | cluster-wide read plus a RoleBinding written into `kube-system` |
| `monitoring` (kube-prometheus-stack) | off | its operator, prometheus, grafana and kube-state-metrics ClusterRoles |
| ingress-nginx | off | one IngressClass ClusterRole, because IngressClass exists only cluster-wide |

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

## Cluster reads gated on the code path that makes them

Outside single-namespace mode, the chart grants a cluster-wide read only under the values
that start the code path using it. The table lists each read whose gate is more than "the
component is enabled".

| Role | Resource | Granted when | Why | Under `singleNamespace` |
|---|---|---|---|---|
| `union-operator-cluster-read` | `nodes` `list,watch` | `disableClusterPermissions` off, and billing model not `None` or `collectUsages.enabled` or `serverlessCollectUsages.enabled` (via `config.configOverrides`) | the operator's node informer, which startup waits on | the same grant, on the same gate: nodes are cluster-scoped, so it is on the single-namespace allowlist |
| `union-operator-cluster-read` | `nodes` `get,list,watch` | `config.operator.clusterHealth.nodeCapacity.enabled`, whatever the row above says | the cluster health snapshot's capacity report; it adds `get` to the same `nodes` rule | the same grant, on the same gate, on the single-namespace allowlist |
| `union-operator-cluster-read` | `pods` `get,list,watch` | `nodeCapacity.enabled` and `nodeCapacity.clusterWidePods` | the capacity report's per-pool usage, read cluster-wide because a namespace-limited operator's pod cache sees only its own namespace | the same grant, on the same gate, on the single-namespace allowlist |
| `union-operator-cluster-read` | `nonResourceURLs: /metrics` `get` | always | the work queue's API-server scrape, which feeds its FlyteWorkflow-count and etcd-size throttles | not granted, matching the chart before the slot model, whose single-namespace Role could not convey it; the throttles stay off there |
| `union-operator-work-ns-cluster-read` | `metrics.k8s.io` `pods` `list` | `collectUsages.enabled`, billing model `ResourceUsage` or `Shadow`, or `serverlessCollectUsages.enabled` with cluster permissions | the usage aggregators' pod-metrics list | `union-operator-comp-ns-read`, on the same conditions |
| `union-flytepropeller-work-ns-cluster-read` | `namespaces` `list` | propeller's `limit-namespace` is empty, `all` or `all-namespaces` | the workflow garbage collector, which cannot delete anything if the List fails | not needed; the collector reads only the release namespace |
| `union-leaseworker-work-ns-cluster-read` | `events.k8s.io` `events` `list,watch` | always | the shared Kubernetes event watcher (`leaseworker/plugin/k8s/event_watcher.go`), a raw informer that watches every namespace when no limit namespace is set; if refused, event enrichment stays empty and startup proceeds | not needed: since cloud#18782 the informer takes the limit namespace, so `work-ns` covers it. A leaseworker image without that change watches cluster-wide and is refused |
| `union-leaseworker-work-ns-cluster-read`, `union-flytepropeller-work-ns-cluster-read` | whatever `taskPluginClusterReadRules` lists, `list,watch` | the key is set | CRD-backed task plugins' informers, which watch every namespace; see [Plugin CRD reads](#plugin-crd-reads-at-singlenamespace-false) | not granted or needed: plugin informers are confined to the release namespace, which `work-ns` covers |
| `union-operator-work-ns-cluster-read` | `configmaps` `list,watch` | `apps.enabled` | see below | covered by `work-ns` |
| `union-operator-work-ns-cluster-read` | `policy` `poddisruptionbudgets` `list,watch` | `apps.enabled` and `config.operator.apps.controller.podDisruptionBudget.enabled` | see below | `work-ns`, under the same gate, beside the writes |

The last two rows are stopgaps. The apps controllers read the `connector-config` ConfigMap
in the release namespace, and each app's PodDisruptionBudget, through a controller-runtime
cache that is not namespace-scoped outside single-namespace mode. The first `Get` starts a
cluster-wide informer and blocks until it syncs. The ConfigMap grant goes away once the
operator reads it through the manager's API reader or scopes the ConfigMap cache to the
release namespace. The PodDisruptionBudget lives in each app's work namespace, which no
cache entry can name in advance, so only the API reader removes that grant.

With PodDisruptionBudget management on, `work-ns` also carries `create`, `update` and
`delete` on `poddisruptionbudgets`, so the operator can manage each app's PDB in its work
namespace.
